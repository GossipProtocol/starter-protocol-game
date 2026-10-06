// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/// @notice Doppler hook callback ABI (DopplerHookInitializer calls these). Redeclared so `src/` never imports Doppler.
interface IDopplerHookCallbacks {
    function onInitialization(address asset, PoolKey calldata key, bytes calldata data) external;

    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external returns (Currency feeCurrency, int128 hookDelta);

    function onGraduation(address asset, PoolKey calldata key, bytes calldata data) external;
}

/**
 * @title BeeefClockHook
 * @notice Doppler hook for beeef round pools. Starts from the no-sell idea of Doppler's NoSellDopplerHook and adds
 * the round clock:
 * - every sell (asset -> numeraire) reverts;
 * - every buy reverts from `lockTime` on;
 * - buys must be exact input (the player sets the USD amount);
 * - the buyer receives `tokensOut * m(t)` where m falls linearly from 1.0 at `startTime` to `floor` at `lockTime`.
 *
 * How the multiplier is charged: DopplerHookInitializer applies the hook's returned delta to the unspecified currency.
 * For an exact-input buy that is the asset, so the withheld share comes out of the side tokens and the player's full
 * USD stake stays in the pool (and later the pot). Exact-output buys are rejected because there the unspecified
 * currency is the numeraire and the "fee" would come out of the pot.
 *
 * Settlement mirrors RehypeDopplerHook: during onSwap the hook `take`s the withheld tokens, leaving itself with a
 * negative PoolManager delta; the initializer then takes the same amount back from the swapper's side and calls
 * `settleFor(hook)`, which zeroes that delta.
 *
 * Withheld tokens: they must never count as winning supply. Burning them here is not possible on Robinhood Chain:
 * DopplerERC20V1 rejects transfers to its locked `pool`, and for prediction markets that pool is address(0), so any
 * burn reverts until Airlock.migrate unlocks it. The hook therefore takes them straight to `sink` (the
 * PredictionMigrator), which burns everything it holds of the entry token as "unsold" at migration, so
 * `claimableSupply` excludes them. The hook itself never holds a token.
 */
contract BeeefClockHook is IDopplerHookCallbacks {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WAD = 1e18;

    struct Clock {
        address asset;
        bool assetIsToken0;
        uint64 startTime;
        uint64 lockTime;
        uint64 floorWad;
    }

    error SenderNotInitializer();
    error SellsNotAllowed();
    error BuysLocked();
    error ExactOutputNotAllowed();
    error InvalidClock();
    error UnknownPool();

    event ClockSet(PoolId indexed poolId, address indexed asset, uint64 startTime, uint64 lockTime, uint64 floorWad);
    event ClockBuy(
        PoolId indexed poolId,
        address indexed asset,
        address indexed sender,
        uint256 numeraireIn,
        uint256 tokensToBuyer,
        uint256 tokensWithheld,
        uint256 multiplierWad
    );

    address public immutable INITIALIZER;
    IPoolManager public immutable POOL_MANAGER;
    /// @notice Receives withheld tokens (the PredictionMigrator, which burns them at migration).
    address public immutable SINK;

    mapping(PoolId poolId => Clock) internal _clocks;
    mapping(address asset => PoolId) public poolIdOf;

    modifier onlyInitializer() {
        require(msg.sender == INITIALIZER, SenderNotInitializer());
        _;
    }

    constructor(address initializer, IPoolManager poolManager, address sink) {
        INITIALIZER = initializer;
        POOL_MANAGER = poolManager;
        SINK = sink;
    }

    // ==================== Doppler callbacks ====================

    /// @param data abi.encode(uint64 startTime, uint64 lockTime, uint64 floorWad)
    function onInitialization(address asset, PoolKey calldata key, bytes calldata data) external onlyInitializer {
        (uint64 startTime, uint64 lockTime, uint64 floorWad) = abi.decode(data, (uint64, uint64, uint64));
        require(lockTime > startTime && floorWad > 0 && floorWad <= WAD, InvalidClock());
        PoolId poolId = key.toId();
        _clocks[poolId] = Clock({
            asset: asset,
            assetIsToken0: Currency.unwrap(key.currency0) == asset,
            startTime: startTime,
            lockTime: lockTime,
            floorWad: floorWad
        });
        poolIdOf[asset] = poolId;
        emit ClockSet(poolId, asset, startTime, lockTime, floorWad);
    }

    function onSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyInitializer returns (Currency, int128) {
        PoolId poolId = key.toId();
        Clock memory c = _clocks[poolId];
        require(c.asset != address(0), UnknownPool());

        // Selling the asset: zeroForOne when the asset is token0, oneForZero when it is token1.
        require(c.assetIsToken0 != params.zeroForOne, SellsNotAllowed());
        require(params.amountSpecified < 0, ExactOutputNotAllowed());
        require(block.timestamp < c.lockTime, BuysLocked());

        int128 out = c.assetIsToken0 ? delta.amount0() : delta.amount1();
        int128 paid = c.assetIsToken0 ? delta.amount1() : delta.amount0();
        if (out <= 0) return (Currency.wrap(address(0)), 0);

        uint256 tokensOut = uint256(uint128(out));
        uint256 m = _multiplier(c, block.timestamp);
        uint256 withheld = tokensOut - tokensOut * m / WAD;

        emit ClockBuy(
            poolId, c.asset, sender, paid < 0 ? uint256(uint128(-paid)) : 0, tokensOut - withheld, withheld, m
        );

        if (withheld == 0) return (Currency.wrap(address(0)), 0);

        Currency asset = Currency.wrap(c.asset);
        // Debits this hook's PoolManager delta; the initializer's settleFor(this) credits it back.
        POOL_MANAGER.take(asset, SINK, withheld);
        return (asset, int128(uint128(withheld)));
    }

    function onGraduation(address, PoolKey calldata, bytes calldata) external onlyInitializer { }

    // ==================== Views ====================

    /// @notice Multiplier (WAD) a buy of `asset` gets at timestamp `t`.
    function multiplierAt(address asset, uint256 t) external view returns (uint256) {
        Clock memory c = _clocks[poolIdOf[asset]];
        require(c.asset != address(0), UnknownPool());
        return _multiplier(c, t);
    }

    function currentMultiplier(address asset) external view returns (uint256) {
        Clock memory c = _clocks[poolIdOf[asset]];
        require(c.asset != address(0), UnknownPool());
        return _multiplier(c, block.timestamp);
    }

    function clockOf(address asset) external view returns (Clock memory) {
        return _clocks[poolIdOf[asset]];
    }

    /// @dev m(t) = 1 - (1 - floor) * (t - start) / (lock - start), clamped to [floor, 1].
    function _multiplier(Clock memory c, uint256 t) internal pure returns (uint256) {
        if (t <= c.startTime) return WAD;
        if (t >= c.lockTime) return c.floorWad;
        return WAD - (WAD - c.floorWad) * (t - c.startTime) / (c.lockTime - c.startTime);
    }
}
