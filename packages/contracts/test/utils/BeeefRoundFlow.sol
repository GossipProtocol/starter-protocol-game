// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console } from "forge-std/console.sol";

import { BeeefFeeSplitter } from "src/BeeefFeeSplitter.sol";
import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";
import { IPredictionMigrator } from "src/interfaces/IDoppler.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { BeeefRoundHelpers } from "test/utils/BeeefRoundHelpers.sol";

/// @notice One full live round (create pair, bet during the race with the falling multiplier, finalize, migrate,
/// claim, roll over) that runs unchanged on a local Doppler deployment and on a Robinhood Chain fork.
abstract contract BeeefRoundFlow is BeeefRoundHelpers {
    function test_fullRound_AWins() public {
        (, uint256 roundId, BeeefOracle oracle, address entryA, address entryB) = _createPair(1 hours);
        BeeefRoundFactory.Round memory r = factory.getRound(roundId);
        uint64 start = r.startTime;

        // ---- Round wiring: live immediately, start price already taken ----
        assertEq(start, block.timestamp, "starts at creation");
        assertEq(r.lockTime, start + 1 hours - LOCK_WINDOW, "locks 60s before the bell");
        assertEq(r.floorWad, FLOOR);
        assertGt(oracle.startSnapshot().takenAt, 0, "start snapshot taken at creation");
        assertEq(migrator.getEntry(address(oracle), factory.ENTRY_ID_A()).token, entryA);
        assertEq(migrator.getEntry(address(oracle), factory.ENTRY_ID_B()).token, entryB);
        assertGt(MockERC20(entryA).balanceOf(creator), 0, "seed A tokens");

        // ---- Bets during the race ----
        uint256 aliceIn = 100e6;
        uint256 bobIn = 50e6;
        uint256 carolIn = 120e6;
        _fund(alice, aliceIn);
        _fund(bob, bobIn);
        _fund(carol, carolIn);
        uint256 aliceTokens = _buy(entryA, alice, aliceIn); // m = 1.00
        vm.warp(start + 20 minutes);
        uint256 carolTokens = _buy(entryB, carol, carolIn);
        vm.warp(start + 40 minutes);
        uint256 bobTokens = _buy(entryA, bob, bobIn); // m ~ 0.39
        assertGt(carolTokens, 0);
        assertLt(bobTokens * aliceIn * 2, aliceTokens * bobIn, "late bet gets far fewer tokens per dollar");
        assertEq(MockERC20(entryA).balanceOf(address(clockHook)), 0, "hook holds nothing");

        // Sells always blocked.
        vm.expectRevert();
        this.trySellExternal(entryA, alice, aliceTokens / 2);

        // Locked for the last 60s.
        vm.warp(r.lockTime);
        _fund(bob, 1e6);
        vm.expectRevert();
        this.buyExternal(entryA, bob, 1e6);

        // ---- Resolve ----
        int256 a0 = oracle.startSnapshot().priceA;
        int256 b0 = oracle.startSnapshot().priceB;
        vm.warp(start + 1 hours);
        _setPrice(feedA, a0 * 103 / 100); // NVDA +3%
        _setPrice(feedB, b0 * 101 / 100); // AMD +1%

        vm.expectRevert(); // migration is gated on finalization
        factory.settle(roundId);

        oracle.finalize();
        (address winner, bool fin) = oracle.getWinner(address(oracle));
        assertTrue(fin);
        assertEq(winner, entryA, "NVDA wins");

        factory.settle(roundId);
        assertTrue(factory.isSettled(roundId));
        assertEq(MockERC20(entryA).balanceOf(address(migrator)), 0, "withheld + unsold tokens burned at migrate");

        IPredictionMigrator.MarketView memory market = migrator.getMarket(address(oracle));
        IPredictionMigrator.EntryView memory eA = migrator.getEntry(address(oracle), factory.ENTRY_ID_A());
        IPredictionMigrator.EntryView memory eB = migrator.getEntry(address(oracle), factory.ENTRY_ID_B());
        uint256 grossIn = aliceIn + bobIn + carolIn + 2 * SEED;
        console.log("pot", market.totalPot, "gross in", grossIn);
        assertEq(market.totalPot, eA.contribution + eB.contribution);
        // Full stakes reach the pot; only the 1% LP fee is taken. The multiplier never touches USD.
        assertApproxEqAbs(market.totalPot, grossIn - grossIn * FEE / 1e6, 100, "pot = stakes - LP fee");

        // claimableSupply = tokens in user hands. Withheld tokens are excluded (they were sent to the migrator and
        // burned). Rounding dust from pool initialization (0xdead, PoolManager) remains, as before.
        uint256 held = aliceTokens + bobTokens + MockERC20(entryA).balanceOf(creator);
        uint256 dust = MockERC20(entryA).balanceOf(address(manager)) + MockERC20(entryA).balanceOf(address(0xdead));
        assertEq(eA.claimableSupply, held + dust, "claimable A = holders + dust, no withheld tokens");
        assertLe(dust, held / 1e6);

        // Fees accrue to the series' fee splitter (the Airlock integrator) and reach the creator's recipients.
        address splitter = factory.getSeries(r.seriesId).feeSplitter;
        uint256 integratorFees = airlock.getIntegratorFees(splitter, usd);
        assertGt(integratorFees, 0, "integrator fees");
        BeeefFeeSplitter(splitter).collectAndDistribute(usd);
        assertEq(MockERC20(usd).balanceOf(integrator), integratorFees, "fees reach the chosen recipient");

        // ---- Claims ----
        uint256 aliceOut = _claim(address(oracle), entryA, alice, aliceTokens);
        uint256 bobOut = _claim(address(oracle), entryA, bob, bobTokens);
        uint256 creatorOut = _claim(address(oracle), entryA, creator, MockERC20(entryA).balanceOf(creator));
        assertEq(aliceOut, aliceTokens * market.totalPot / eA.claimableSupply);
        assertGt(aliceOut * bobIn, bobOut * aliceIn * 2, "early bettor earns far more per dollar");
        assertApproxEqRel(aliceOut + bobOut + creatorOut, market.totalPot, 1e12, "pot distributed up to dust");
        assertLe(aliceOut + bobOut + creatorOut, market.totalPot);

        vm.startPrank(carol);
        MockERC20(entryB).approve(address(migrator), carolTokens);
        vm.expectRevert();
        migrator.claim(address(oracle), carolTokens);
        vm.stopPrank();
    }

    function test_fullRound_RollsOverWithoutGap() public {
        (uint256 seriesId, uint256 r0,,,) = _createPair(1 hours);
        _fundRollovers(2);
        BeeefRoundFactory.Round memory prev = factory.getRound(r0);
        BeeefOracle prevOracle = BeeefOracle(prev.oracle);

        vm.warp(prev.endTime + 30);
        _setPrice(feedA, prevOracle.startSnapshot().priceA * 101 / 100);
        _setPrice(feedB, prevOracle.startSnapshot().priceB);
        uint256 r1 = factory.rollover(seriesId); // finalizes r0, then starts r1

        BeeefRoundFactory.Round memory next = factory.getRound(r1);
        assertTrue(prevOracle.finalized());
        assertEq(next.startTime, prev.endTime, "no gap, no overlap");
        assertEq(next.prevRoundId, r0);
        assertTrue(next.carriedStart);
        assertEq(next.seriesId, prev.seriesId);
        assertEq(next.roundNumber, 2);
        BeeefOracle.Snapshot memory endPrev = prevOracle.endSnapshot();
        BeeefOracle.Snapshot memory startNext = BeeefOracle(next.oracle).startSnapshot();
        assertEq(startNext.priceA, endPrev.priceA, "start price = previous end price");
        assertEq(startNext.priceB, endPrev.priceB);
        assertEq(factory.currentRoundId(seriesId), r1);

        // Bets are open on the new round right away.
        _fund(alice, 10e6);
        assertGt(_buy(next.entryA, alice, 10e6), 0);
    }

    function test_fullRound_TieVoid_FundsStuckWithoutRefund() public {
        (, uint256 roundId, BeeefOracle oracle, address entryA,) = _createPair(1 hours);
        _fund(alice, 10e6);
        uint256 aliceTokens = _buy(entryA, alice, 10e6);

        vm.warp(factory.getRound(roundId).endTime);
        _setPrice(feedA, oracle.startSnapshot().priceA);
        _setPrice(feedB, oracle.startSnapshot().priceB);
        oracle.finalize(); // no price change -> exact tie
        assertTrue(oracle.isVoid());

        factory.settle(roundId);
        assertGt(migrator.getMarket(address(oracle)).totalPot, 0);
        vm.startPrank(alice);
        MockERC20(entryA).approve(address(migrator), aliceTokens);
        vm.expectRevert();
        migrator.claim(address(oracle), aliceTokens);
        vm.stopPrank();
    }

    function buyExternal(address entry, address buyer, uint256 amount) external returns (uint256) {
        return _buy(entry, buyer, amount);
    }
}
