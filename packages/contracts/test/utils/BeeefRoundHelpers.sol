// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { BeeefTestBase } from "test/utils/BeeefTestBase.sol";

/// @notice Round-level helpers shared by the local and fork setups.
abstract contract BeeefRoundHelpers is BeeefTestBase {
    address internal stockA;
    address internal stockB;
    address internal feedA;
    address internal feedB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant SEED = 1e6; // 1 USD per side

    /// @dev Sets the price the feed reports from now on (updatedAt = block.timestamp).
    function _setPrice(address feed, int256 answer) internal virtual;

    function _price(address feed) internal view virtual returns (int256);

    function _registerStocks() internal {
        vm.startPrank(admin);
        registry.setStock(stockA, feedA, "NVDA");
        registry.setStock(stockB, feedB, "AMD");
        vm.stopPrank();
    }

    /// @dev Seed-bought per side in tests; a round costs 2 x SEED.
    uint256 internal constant ROUND_SEED = 2 * SEED;
    uint256 internal lastSeriesId;

    function _fees() internal view returns (BeeefRoundFactory.FeeSplit memory f) {
        f.recipients = new address[](1);
        f.recipients[0] = integrator;
        f.bps = new uint16[](1);
        f.bps[0] = 10_000;
    }

    /// @dev Recurring series with no end, funded for one round (top up with _fundRollovers). The first round starts
    /// now, with its start snapshot taken in the same tx.
    function _createPair(uint64 duration)
        internal
        returns (uint256 seriesId, uint256 roundId, BeeefOracle oracle, address entryA, address entryB)
    {
        return _createSeries(duration, BeeefRoundFactory.SeriesEnd(0, 0), 1);
    }

    function _createSeries(
        uint64 duration,
        BeeefRoundFactory.SeriesEnd memory end,
        uint256 roundsFunded
    ) internal returns (uint256 seriesId, uint256 roundId, BeeefOracle oracle, address entryA, address entryB) {
        uint256 deposit = ROUND_SEED * roundsFunded;
        _fund(creator, deposit);
        vm.startPrank(creator);
        MockERC20(usd).approve(address(factory), deposit);
        (seriesId, roundId) = factory.createSeries(stockA, stockB, duration, _fees(), end, ROUND_SEED, deposit);
        vm.stopPrank();
        (oracle, entryA, entryB) = _unpack(roundId);
        lastSeriesId = seriesId;
    }

    function _createOneOff(uint64 duration)
        internal
        returns (uint256 seriesId, uint256 roundId, BeeefOracle oracle, address entryA, address entryB)
    {
        _fund(creator, ROUND_SEED);
        vm.startPrank(creator);
        MockERC20(usd).approve(address(factory), ROUND_SEED);
        (seriesId, roundId) = factory.createOneOff(stockA, stockB, duration, _fees(), ROUND_SEED);
        vm.stopPrank();
        (oracle, entryA, entryB) = _unpack(roundId);
        lastSeriesId = seriesId;
    }

    function _unpack(uint256 roundId) internal view returns (BeeefOracle oracle, address entryA, address entryB) {
        BeeefRoundFactory.Round memory r = factory.getRound(roundId);
        oracle = BeeefOracle(r.oracle);
        entryA = r.entryA;
        entryB = r.entryB;
    }

    /// @dev Tops up the latest series' seed for `rounds` more rounds.
    function _fundRollovers(uint256 rounds) internal {
        address funder = makeAddr("funder");
        _fund(funder, ROUND_SEED * rounds);
        vm.startPrank(funder);
        MockERC20(usd).approve(address(factory), ROUND_SEED * rounds);
        factory.topUpSeed(lastSeriesId, ROUND_SEED * rounds);
        vm.stopPrank();
    }

    function trySellExternal(address entry, address seller, uint256 amount) external {
        _trySell(entry, seller, amount);
    }

    function _claim(address oracle, address entry, address who, uint256 amount) internal returns (uint256 out) {
        uint256 before = MockERC20(usd).balanceOf(who);
        vm.startPrank(who);
        MockERC20(entry).approve(address(migrator), amount);
        migrator.claim(oracle, amount);
        vm.stopPrank();
        out = MockERC20(usd).balanceOf(who) - before;
    }
}
