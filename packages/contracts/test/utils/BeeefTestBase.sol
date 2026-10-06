// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

// Doppler (BUSL-1.1) is only imported by tests, never by src/.
import { Airlock, ModuleState } from "doppler/Airlock.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "doppler/base/BaseDopplerHook.sol";
import { DopplerHookInitializer } from "doppler/initializers/DopplerHookInitializer.sol";
import { PredictionMigrator } from "doppler/migrators/PredictionMigrator.sol";

import { BeeefClockHook } from "src/BeeefClockHook.sol";
import { BeeefFeeSplitter } from "src/BeeefFeeSplitter.sol";
import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRegistry } from "src/BeeefRegistry.sol";
import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";
import { Curve, IPredictionMigrator } from "src/interfaces/IDoppler.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";

/// @notice Shared wiring for local and Robinhood Chain fork tests.
abstract contract BeeefTestBase is Test {
    Airlock internal airlock;
    IPoolManager internal manager;
    DopplerHookInitializer internal initializer;
    /// @dev Typed as beeef's redeclared interface: every call doubles as an ABI compatibility check.
    IPredictionMigrator internal migrator;
    BeeefClockHook internal clockHook;
    address internal tokenFactory;
    BeeefRoundFactory.TokenFactoryKind internal tokenFactoryKind;
    address internal governanceFactory;
    address internal usd; // numeraire
    PoolSwapTest internal swapRouter;

    BeeefRoundFactory internal factory;
    BeeefRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal creator = makeAddr("creator");
    address internal integrator = makeAddr("integrator");

    uint24 internal constant FEE = 10_000; // 1%
    int24 internal constant TICK_SPACING = 8;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint32 internal constant SNAPSHOT_WINDOW = 5 minutes;
    uint32 internal constant MAX_STALENESS = 25 hours; // Robinhood feeds: 24h heartbeat + margin
    uint32 internal constant LOCK_WINDOW = 60;
    uint64 internal constant FLOOR = 0.1e18;

    // ==================== Doppler module helpers ====================

    function _whitelist(address module, ModuleState state) internal {
        address[] memory modules = new address[](1);
        modules[0] = module;
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = state;
        vm.prank(airlock.owner());
        airlock.setModuleState(modules, states);
    }

    /// @dev Deploys a PredictionMigrator and BeeefClockHook for the test, then whitelists and registers them by
    /// pranking the Airlock owner. On a live chain the Airlock owner registers modules; tests stand in for that.
    function _deployPredictionModules() internal {
        migrator = IPredictionMigrator(address(new PredictionMigrator(address(airlock))));
        _whitelist(address(migrator), ModuleState.LiquidityMigrator);

        clockHook = new BeeefClockHook(address(initializer), manager, address(migrator));
        address[] memory hooks = new address[](1);
        hooks[0] = address(clockHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
        vm.prank(airlock.owner());
        initializer.setDopplerHookState(hooks, flags);
    }

    /// @dev Near-flat curve for a 6-decimal USD numeraire and 18-decimal entry tokens, in "asset is token0"
    /// orientation (price = 1.0001^tick numeraire-wei per asset-wei). 1B tokens between tick -322376 (~$0.0100) and
    /// -320376 (~$0.0122): the price rises at most ~22% across the whole supply (~$11M per side), so a bet barely
    /// moves it and the clock multiplier is the only thing that rewards betting early.
    function _defaultPoolConfig() internal pure returns (BeeefRegistry.PoolConfig memory pool) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: -322_376, tickUpper: -320_376, numPositions: 20, shares: 1e18 });
        pool = BeeefRegistry.PoolConfig({ fee: FEE, tickSpacing: TICK_SPACING, supply: SUPPLY, curves: curves });
    }

    function _deployFactory() internal {
        BeeefOracle impl = new BeeefOracle();
        registry = new BeeefRegistry(
            admin,
            _defaultPoolConfig(),
            BeeefRegistry.OracleSettings({
                snapshotWindow: SNAPSHOT_WINDOW,
                maxStaleness: MAX_STALENESS,
                sequencerFeed: address(0),
                sequencerGracePeriod: 0,
                applyMultiplier: false
            }),
            BeeefRegistry.ClockSettings({ lockWindow: LOCK_WINDOW, lockBps: 1000, floorWad: FLOOR }),
            1e6 // min seed: 1 USD
        );
        factory = new BeeefRoundFactory(
            admin,
            BeeefRoundFactory.Modules({
                airlock: address(airlock),
                poolManager: address(manager),
                poolInitializer: address(initializer),
                migrator: address(migrator),
                dopplerHook: address(clockHook),
                tokenFactory: tokenFactory,
                tokenFactoryKind: tokenFactoryKind,
                governanceFactory: governanceFactory,
                numeraire: usd,
                oracleImplementation: address(impl),
                feeSplitterImplementation: address(new BeeefFeeSplitter())
            }),
            registry
        );
        swapRouter = new PoolSwapTest(manager);
    }

    // ==================== Trading helpers ====================

    function _fund(address who, uint256 amount) internal virtual;

    /// @dev Exact-input buy of an entry token with the numeraire through the v4 pool.
    function _buy(address entry, address buyer, uint256 amountIn) internal returns (uint256 tokensOut) {
        PoolKey memory key = factory.poolKeyOf(entry);
        bool zeroForOne = address(uint160(key.currency0.toId())) == usd;
        uint256 before = MockERC20(entry).balanceOf(buyer);
        vm.startPrank(buyer);
        MockERC20(usd).approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        vm.stopPrank();
        tokensOut = MockERC20(entry).balanceOf(buyer) - before;
    }

    /// @dev Exact-output buy (asks for a token amount), expected to revert through BeeefClockHook.
    function _tryBuyExactOut(address entry, address buyer, uint256 tokensOut, uint256 maxIn) internal {
        PoolKey memory key = factory.poolKeyOf(entry);
        bool zeroForOne = address(uint160(key.currency0.toId())) == usd;
        vm.startPrank(buyer);
        MockERC20(usd).approve(address(swapRouter), maxIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(tokensOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Exact-input sell of an entry token, expected to revert through BeeefClockHook.
    function _trySell(address entry, address seller, uint256 amountIn) internal {
        PoolKey memory key = factory.poolKeyOf(entry);
        bool zeroForOne = address(uint160(key.currency0.toId())) == entry;
        vm.startPrank(seller);
        MockERC20(entry).approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        vm.stopPrank();
    }

    function _hookFlagsAddress() internal pure returns (address) {
        return address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
    }
}
