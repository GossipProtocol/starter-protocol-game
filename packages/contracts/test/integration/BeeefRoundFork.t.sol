// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console } from "forge-std/console.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";

import { Airlock } from "doppler/Airlock.sol";
import { DopplerHookInitializer } from "doppler/initializers/DopplerHookInitializer.sol";

import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";
import { IAggregatorV3 } from "src/interfaces/IAggregatorV3.sol";
import { IRobinhoodStockToken } from "src/interfaces/IRobinhoodStockToken.sol";

import { BeeefRoundFlow } from "test/utils/BeeefRoundFlow.sol";
import { RobinhoodAddresses as RH } from "test/utils/RobinhoodAddresses.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @notice Full round on a Robinhood Chain (4663) fork using the live Airlock, PoolManager, DopplerHookInitializer,
/// DopplerERC20V1Factory, NoOpGovernanceFactory, USDG, NVDA/AMD stock tokens and their Chainlink feeds.
/// The test deploys its own PredictionMigrator and BeeefClockHook and whitelists / registers them by pranking the
/// Airlock owner, so it needs no module registration on the live chain.
/// Feed answers are read live at fork time, then pinned with vm.mockCall so the test controls the price move.
/// Skipped when ROBINHOOD_RPC_URL is not set.
contract BeeefRoundForkTest is BeeefRoundFlow {
    mapping(address feed => uint80) internal _mockRound;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 4663, "not Robinhood Chain");

        airlock = Airlock(payable(RH.AIRLOCK));
        manager = IPoolManager(RH.POOL_MANAGER);
        initializer = DopplerHookInitializer(payable(RH.DOPPLER_HOOK_INITIALIZER));
        tokenFactory = RH.DOPPLER_ERC20_V1_FACTORY;
        tokenFactoryKind = BeeefRoundFactory.TokenFactoryKind.DopplerERC20V1;
        governanceFactory = RH.NO_OP_GOVERNANCE_FACTORY;
        usd = RH.USDG;

        _deployPredictionModules();
        _deployFactory();

        stockA = RH.NVDA;
        stockB = RH.AMD;
        feedA = RH.NVDA_USD_FEED;
        feedB = RH.AMD_USD_FEED;
        _registerStocks();

        // Live sanity checks on the real feeds and tokens.
        for (uint256 i; i < 2; ++i) {
            address feed = i == 0 ? feedA : feedB;
            address stock = i == 0 ? stockA : stockB;
            (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
            console.log("feed", feed);
            console.log("  answer", uint256(answer), "age (s)", block.timestamp - updatedAt);
            console.log("  uiMultiplier", IRobinhoodStockToken(stock).uiMultiplier());
            assertEq(IAggregatorV3(feed).decimals(), 8);
            assertGt(answer, 0);
        }

        // Rounds must sit inside the 24/5 session. If the fork lands on a weekend, move to the next open window;
        // feeds are mocked from here on so their age does not matter.
        _setPrice(feedA, _price(feedA));
        _setPrice(feedB, _price(feedB));
        while (!registry.isMarketOpen(block.timestamp + 10 minutes, block.timestamp + 2 hours)) {
            vm.warp(block.timestamp + 1 hours);
        }
    }

    function _fund(address who, uint256 amount) internal override {
        deal(usd, who, amount);
    }

    function _setPrice(address feed, int256 answer) internal override {
        uint80 id = ++_mockRound[feed] + type(uint64).max; // above live round ids, like a new phase
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(id, answer, block.timestamp, block.timestamp, id)
        );
    }

    function _price(address feed) internal view override returns (int256 answer) {
        (, answer,,,) = IAggregatorV3(feed).latestRoundData();
    }

    /// Why BeeefClockHook routes withheld tokens to the migrator instead of burning them: on 4663 the entry token
    /// (DopplerERC20V1) rejects transfers to its locked pool, which is address(0) for prediction markets, so every
    /// burn reverts until Airlock.migrate unlocks it.
    function test_fork_entryTokenCannotBurnWhileRoundIsLive() public {
        (,,, address entryA,) = _createPair(1 hours);
        _fund(alice, 10e6);
        uint256 tokens = _buy(entryA, alice, 10e6);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("PoolLocked()")));
        IBurnable(entryA).burn(tokens);
    }

    function test_fork_modulesAreLive() public view {
        assertEq(address(initializer.airlock()), RH.AIRLOCK);
        assertEq(address(initializer.poolManager()), RH.POOL_MANAGER);
        assertEq(uint8(airlock.getModuleState(RH.DOPPLER_HOOK_INITIALIZER)), 3, "initializer whitelisted");
        assertEq(uint8(airlock.getModuleState(RH.DOPPLER_ERC20_V1_FACTORY)), 1, "token factory whitelisted");
        assertEq(uint8(airlock.getModuleState(RH.NO_OP_GOVERNANCE_FACTORY)), 2, "governance factory whitelisted");
        assertEq(uint8(airlock.getModuleState(address(migrator))), 4, "migrator whitelisted (pranked)");
    }
}
