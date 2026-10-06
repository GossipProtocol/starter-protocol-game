// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@solady/auth/Ownable.sol";

import { BeeefClockHook } from "src/BeeefClockHook.sol";
import { BeeefFeeSplitter } from "src/BeeefFeeSplitter.sol";
import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRegistry } from "src/BeeefRegistry.sol";
import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";
import { CourseFee } from "src/CourseFee.sol";
import { Curve } from "src/interfaces/IDoppler.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockStockToken } from "test/mocks/MockStockToken.sol";
import { LocalDopplerSetup } from "test/utils/LocalDopplerSetup.sol";

contract BeeefRoundFactoryTest is LocalDopplerSetup {
    // setUp warps to 1_790_000_000 = Monday 2026-09-21 14:13:20 UTC.
    uint256 internal constant MONDAY = 1_789_948_800; // Monday 00:00 UTC
    uint256 internal constant FRIDAY = MONDAY + 4 days;
    uint256 internal constant SATURDAY = MONDAY + 5 days;
    uint256 internal constant SUNDAY = MONDAY + 6 days;
    uint256 internal constant NEXT_MONDAY = MONDAY + 7 days;
    uint256 internal constant NEXT_OPEN = NEXT_MONDAY + 1 hours; // weekly close ends Monday 01:00 UTC

    function _noEnd() internal pure returns (BeeefRoundFactory.SeriesEnd memory) {
        return BeeefRoundFactory.SeriesEnd(0, 0);
    }

    function _expectSeriesRevert(
        address a,
        address b,
        uint64 duration,
        BeeefRoundFactory.SeriesEnd memory end,
        uint256 seedPerRound,
        uint256 deposit,
        bytes memory err
    ) internal {
        _fund(creator, deposit);
        vm.startPrank(creator);
        MockERC20(usd).approve(address(factory), deposit);
        vm.expectRevert(err);
        factory.createSeries(a, b, duration, _fees(), end, seedPerRound, deposit);
        vm.stopPrank();
    }

    /// @dev Ends the series' current round with fresh prices (A +1%) and rolls over.
    function _endAndRoll(uint256 seriesId, uint256 after_) internal returns (uint256 prevId, uint256 nextId) {
        prevId = factory.currentRoundId(seriesId);
        BeeefRoundFactory.Round memory prev = factory.getRound(prevId);
        vm.warp(prev.endTime + after_);
        _setPrice(feedA, BeeefOracle(prev.oracle).startSnapshot().priceA * 101 / 100);
        _setPrice(feedB, BeeefOracle(prev.oracle).startSnapshot().priceB);
        nextId = factory.rollover(seriesId);
    }

    // ==================== createSeries ====================

    function test_createSeries_StartsLiveRoundNow() public {
        (uint256 seriesId, uint256 roundId, BeeefOracle oracle, address entryA, address entryB) =
            _createSeries(1 hours, BeeefRoundFactory.SeriesEnd(50, 0), 3);

        BeeefRoundFactory.Series memory s = factory.getSeries(seriesId);
        assertTrue(s.recurring);
        assertTrue(s.active);
        assertEq(s.duration, 1 hours);
        assertEq(s.roundsTotal, 50);
        assertEq(s.roundsPlayed, 1);
        assertEq(s.creator, creator);
        assertEq(s.seedPerRound, ROUND_SEED);
        assertEq(s.seedBalance, ROUND_SEED * 2, "one round's seed spent");
        assertEq(s.lastRoundId, roundId);
        assertTrue(s.feeSplitter != address(0));

        uint256 pairId = factory.pairIdOf(stockA, stockB);
        assertEq(factory.pairIdOf(stockB, stockA), pairId, "pair is order independent");
        assertEq(s.pairId, pairId);
        assertTrue(factory.getPair(pairId).active);

        BeeefRoundFactory.Round memory r = factory.getRound(roundId);
        assertEq(r.seriesId, seriesId);
        assertEq(r.pairId, pairId);
        assertEq(r.roundNumber, 1);
        assertEq(r.prevRoundId, factory.NO_ROUND());
        assertEq(r.startTime, block.timestamp);
        assertEq(r.endTime, block.timestamp + 1 hours);
        assertEq(r.lockTime, block.timestamp + 1 hours - 60);
        assertEq(r.floorWad, FLOOR);
        assertFalse(r.carriedStart, "first round takes a fresh start price");
        assertEq(oracle.startSnapshot().takenAt, block.timestamp);
        assertEq(factory.roundIdOf(address(oracle)), roundId);

        BeeefClockHook.Clock memory c = clockHook.clockOf(entryA);
        assertEq(c.startTime, r.startTime);
        assertEq(c.lockTime, r.lockTime);
        assertEq(clockHook.clockOf(entryB).floorWad, FLOOR);

        assertGt(MockERC20(entryA).balanceOf(creator), 0, "creator gets the seed tokens");
        assertEq(MockERC20(entryA).symbol(), "bNVDA-0");
        assertEq(MockERC20(usd).balanceOf(address(factory)), ROUND_SEED * 2, "factory holds only the unspent seed");
    }

    function test_createSeries_MarketClosed_QueuesForTheOpen() public {
        vm.warp(SATURDAY + 10 hours);
        (, uint256 roundId, BeeefOracle oracle,,) = _createPair(1 hours);
        assertEq(factory.getRound(roundId).startTime, NEXT_OPEN);
        assertEq(oracle.startSnapshot().takenAt, 0, "start price taken at the open");
        vm.warp(NEXT_OPEN);
        _setPrice(feedA, 181e8);
        _setPrice(feedB, 160e8);
        oracle.snapshotStart();
        assertEq(oracle.startSnapshot().priceA, 181e8);
    }

    function test_createSeries_Holiday_QueuesToNextDay() public {
        uint256 today = block.timestamp / 1 days;
        vm.prank(admin);
        registry.setClosedDay(today, true);
        (, uint256 roundId,,,) = _createPair(1 hours);
        assertEq(factory.getRound(roundId).startTime, (today + 1) * 1 days);
    }

    function test_createSeries_Reverts() public {
        address rogue = address(new MockStockToken());
        _expectSeriesRevert(
            stockA,
            rogue,
            1 hours,
            _noEnd(),
            ROUND_SEED,
            ROUND_SEED,
            abi.encodeWithSelector(BeeefRoundFactory.StockNotAllowed.selector, rogue)
        );
        _expectSeriesRevert(
            stockA,
            stockA,
            1 hours,
            _noEnd(),
            ROUND_SEED,
            ROUND_SEED,
            abi.encodeWithSelector(BeeefRoundFactory.SameStock.selector)
        );
        _expectSeriesRevert(
            stockA,
            stockB,
            45 minutes,
            _noEnd(),
            ROUND_SEED,
            ROUND_SEED,
            abi.encodeWithSelector(BeeefRoundFactory.DurationNotAllowed.selector, 45 minutes)
        );
        _expectSeriesRevert(
            stockA,
            stockB,
            1 hours,
            _noEnd(),
            ROUND_SEED - 2,
            ROUND_SEED,
            abi.encodeWithSelector(BeeefRoundFactory.SeedTooSmall.selector)
        );
        _expectSeriesRevert(
            stockA,
            stockB,
            1 hours,
            _noEnd(),
            ROUND_SEED,
            ROUND_SEED - 1,
            abi.encodeWithSelector(BeeefRoundFactory.SeedFundsLow.selector, ROUND_SEED, ROUND_SEED - 1)
        );
        _expectSeriesRevert(
            stockA,
            stockB,
            1 hours,
            BeeefRoundFactory.SeriesEnd(0, uint64(block.timestamp)),
            ROUND_SEED,
            ROUND_SEED,
            abi.encodeWithSelector(BeeefRoundFactory.InvalidSeriesEnd.selector)
        );
    }

    function test_createSeries_RevertsWhen_PairSwitchedOff() public {
        _createPair(1 hours);
        uint256 pairId = factory.pairIdOf(stockA, stockB);
        vm.prank(admin);
        factory.setPairActive(pairId, false);
        _expectSeriesRevert(
            stockA,
            stockB,
            1 hours,
            _noEnd(),
            ROUND_SEED,
            ROUND_SEED,
            abi.encodeWithSelector(BeeefRoundFactory.PairPaused.selector)
        );
    }

    function test_createSeries_InvalidFeeSplitReverts() public {
        BeeefRoundFactory.FeeSplit memory f;
        f.recipients = new address[](2);
        f.recipients[0] = integrator;
        f.recipients[1] = creator;
        f.bps = new uint16[](2);
        f.bps[0] = 5000;
        f.bps[1] = 4000; // sums to 90%
        _fund(creator, ROUND_SEED);
        vm.startPrank(creator);
        MockERC20(usd).approve(address(factory), ROUND_SEED);
        vm.expectRevert(BeeefFeeSplitter.InvalidSplit.selector);
        factory.createSeries(stockA, stockB, 1 hours, f, _noEnd(), ROUND_SEED, ROUND_SEED);
        vm.stopPrank();
    }

    function test_severalSeriesOnOnePair() public {
        (uint256 s0, uint256 r0,,,) = _createSeries(30 minutes, _noEnd(), 1);
        (uint256 s1, uint256 r1,,,) = _createSeries(1 hours, _noEnd(), 1);
        assertTrue(s0 != s1);
        assertEq(factory.getSeries(s0).pairId, factory.getSeries(s1).pairId, "same rivalry");
        assertTrue(factory.getRound(r0).oracle != factory.getRound(r1).oracle, "separate markets");
        assertEq(factory.getRound(r0).endTime - factory.getRound(r0).startTime, 30 minutes);
        assertEq(factory.getRound(r1).endTime - factory.getRound(r1).startTime, 1 hours);
        assertEq(factory.pairCount(), 1);
    }

    // ==================== createOneOff ====================

    function test_oneOff_SingleRound_NeverRollsOver() public {
        (uint256 seriesId, uint256 roundId, BeeefOracle oracle, address entryA,) = _createOneOff(1 hours);
        BeeefRoundFactory.Series memory s = factory.getSeries(seriesId);
        assertFalse(s.recurring);
        assertFalse(s.active);
        assertEq(s.roundsPlayed, 1);
        assertEq(s.seedBalance, 0);
        assertEq(oracle.startSnapshot().takenAt, block.timestamp, "fresh start price");

        _fund(alice, 10e6);
        uint256 tokens = _buy(entryA, alice, 10e6);
        BeeefRoundFactory.Round memory r = factory.getRound(roundId);
        vm.warp(r.endTime);
        _setPrice(feedA, oracle.startSnapshot().priceA * 101 / 100);
        _setPrice(feedB, oracle.startSnapshot().priceB);
        oracle.finalize();
        factory.settle(roundId);
        assertGt(_claim(address(oracle), entryA, alice, tokens), 10e6);

        vm.expectRevert(BeeefRoundFactory.NotRecurring.selector);
        factory.rollover(seriesId);
        vm.expectRevert(BeeefRoundFactory.SeriesNotActive.selector);
        factory.topUpSeed(seriesId, 1);
    }

    function test_oneOff_MarketClosed_QueuesForTheOpen() public {
        vm.warp(SATURDAY + 3 hours);
        (, uint256 roundId,,,) = _createOneOff(10 minutes);
        assertEq(factory.getRound(roundId).startTime, NEXT_OPEN);
    }

    // ==================== rematch ====================

    function _finishRound(uint256 roundId) internal {
        BeeefRoundFactory.Round memory r = factory.getRound(roundId);
        vm.warp(r.endTime);
        _setPrice(feedA, BeeefOracle(r.oracle).startSnapshot().priceA * 101 / 100);
        _setPrice(feedB, BeeefOracle(r.oracle).startSnapshot().priceB);
        BeeefOracle(r.oracle).finalize();
    }

    function _startRematch(
        address who,
        uint256 prevRoundId,
        bool sideA,
        uint256 amount
    ) internal returns (uint256 seriesId, uint256 roundId) {
        _fund(who, amount + SEED);
        vm.startPrank(who);
        MockERC20(usd).approve(address(factory), amount + SEED);
        (seriesId, roundId) = factory.rematch(prevRoundId, sideA, amount);
        vm.stopPrank();
    }

    function test_rematch_NotAutomatic_StartedByAPlayersBet() public {
        (uint256 s0, uint256 r0,,,) = _createOneOff(30 minutes);
        _finishRound(r0);
        (bool exists,) = factory.rematchOf(r0);
        assertFalse(exists, "nothing starts on its own");
        assertEq(factory.roundCount(), 1);

        (uint256 s1, uint256 r1) = _startRematch(bob, r0, true, 25e6);
        (exists,) = factory.rematchOf(r0);
        assertTrue(exists);
        (, uint256 found) = factory.rematchOf(r0);
        assertEq(found, r1);

        BeeefRoundFactory.Series memory prev = factory.getSeries(s0);
        BeeefRoundFactory.Series memory next = factory.getSeries(s1);
        BeeefRoundFactory.Round memory r = factory.getRound(r1);
        assertEq(next.pairId, prev.pairId, "same pair");
        assertEq(next.duration, prev.duration, "same length");
        assertEq(next.feeSplitter, prev.feeSplitter, "same fee recipients as the original");
        assertEq(next.creator, bob);
        assertFalse(next.recurring);
        assertEq(r.startTime, block.timestamp, "live now");
        assertEq(BeeefOracle(r.oracle).startSnapshot().takenAt, block.timestamp, "fresh start price");

        // Bob's bet bought side A at 1.00x; he also holds the minimum seed on side B.
        uint256 aTokens = MockERC20(r.entryA).balanceOf(bob);
        uint256 bTokens = MockERC20(r.entryB).balanceOf(bob);
        assertGt(aTokens, bTokens * 20, "his bet is on A");
        assertGt(bTokens, 0, "other side seeded so it can pay out");
        assertEq(MockERC20(usd).balanceOf(address(factory)), 0);

        // Others join the same rematch instead of starting another.
        _fund(alice, 10e6);
        assertGt(_buy(r.entryB, alice, 10e6), 0);
        _fund(carol, 30e6);
        vm.startPrank(carol);
        MockERC20(usd).approve(address(factory), 30e6);
        vm.expectRevert(abi.encodeWithSelector(BeeefRoundFactory.RematchExists.selector, r1));
        factory.rematch(r0, false, 20e6);
        vm.stopPrank();
    }

    function test_rematch_Reverts() public {
        (, uint256 r0,,,) = _createOneOff(30 minutes);
        vm.expectRevert(BeeefRoundFactory.RoundNotOver.selector);
        factory.rematch(r0, true, 25e6);

        _finishRound(r0);
        _fund(bob, SEED * 2);
        vm.startPrank(bob);
        MockERC20(usd).approve(address(factory), SEED * 2);
        vm.expectRevert(BeeefRoundFactory.SeedTooSmall.selector);
        factory.rematch(r0, true, SEED - 1);
        vm.stopPrank();

        (, uint256 rs,,,) = _createSeries(30 minutes, _noEnd(), 1);
        _finishRound(rs);
        vm.expectRevert(BeeefRoundFactory.NotOneOff.selector);
        factory.rematch(rs, true, 25e6);
    }

    // ==================== rollover ====================

    function test_rollover_NoGapNoOverlap_ThreeRounds() public {
        (uint256 seriesId,,,,) = _createSeries(30 minutes, _noEnd(), 4);
        for (uint256 i; i < 3; ++i) {
            (uint256 prevId, uint256 nextId) = _endAndRoll(seriesId, 10);
            BeeefRoundFactory.Round memory prev = factory.getRound(prevId);
            BeeefRoundFactory.Round memory next = factory.getRound(nextId);
            assertEq(next.startTime, prev.endTime, "starts exactly at the previous end");
            assertEq(next.endTime, next.startTime + 30 minutes);
            assertEq(next.prevRoundId, prevId);
            assertEq(next.roundNumber, i + 2);
            assertTrue(next.carriedStart);
            assertEq(
                BeeefOracle(next.oracle).startSnapshot().priceA,
                BeeefOracle(prev.oracle).endSnapshot().priceA,
                "start price carried over"
            );
        }
        assertEq(factory.getSeries(seriesId).seedBalance, 0, "one seed per round");
        assertEq(factory.getSeries(seriesId).roundsPlayed, 4);
    }

    function test_rollover_RoundsLimit_ExhaustsAndRefunds() public {
        (uint256 seriesId,,,,) = _createSeries(30 minutes, BeeefRoundFactory.SeriesEnd(2, 0), 5);
        _endAndRoll(seriesId, 10); // round 2 of 2
        uint256 lastId = factory.currentRoundId(seriesId);
        uint256 before = MockERC20(usd).balanceOf(creator);

        (, uint256 nextId) = _endAndRoll(seriesId, 10);
        assertEq(nextId, factory.NO_ROUND(), "no third round");
        assertEq(factory.currentRoundId(seriesId), lastId);
        assertFalse(factory.getSeries(seriesId).active);
        assertEq(factory.getSeries(seriesId).seedBalance, 0);
        assertEq(MockERC20(usd).balanceOf(creator) - before, ROUND_SEED * 3, "unused seed refunded");
        assertTrue(BeeefOracle(factory.getRound(lastId).oracle).finalized(), "last round still finalized");

        vm.expectRevert(BeeefRoundFactory.SeriesNotActive.selector);
        factory.rollover(seriesId);
    }

    function test_rollover_EndTime_Exhausts() public {
        uint64 endTime = uint64(block.timestamp + 90 minutes);
        (uint256 seriesId,,,,) = _createSeries(1 hours, BeeefRoundFactory.SeriesEnd(0, endTime), 3);
        (, uint256 r2) = _endAndRoll(seriesId, 10); // starts at +60m, before the end date
        assertTrue(r2 != factory.NO_ROUND());
        (, uint256 r3) = _endAndRoll(seriesId, 10); // would start at +120m, past it
        assertEq(r3, factory.NO_ROUND());
        assertFalse(factory.getSeries(seriesId).active);
    }

    function test_rollover_SeedLow_RevertsUntilToppedUp() public {
        (uint256 seriesId, uint256 r0,,,) = _createPair(1 hours); // funded for one round only
        BeeefRoundFactory.Round memory r = factory.getRound(r0);
        vm.warp(r.endTime + 5);
        _setPrice(feedA, 181e8);
        _setPrice(feedB, 160e8);
        vm.expectRevert(abi.encodeWithSelector(BeeefRoundFactory.SeedFundsLow.selector, ROUND_SEED, 0));
        factory.rollover(seriesId);

        _fundRollovers(1); // anyone can top up
        assertEq(factory.getSeries(seriesId).seedBalance, ROUND_SEED);
        uint256 next = factory.rollover(seriesId);
        assertEq(factory.getRound(next).startTime, r.endTime);
    }

    function test_stopSeries_RefundsAndStops() public {
        (uint256 seriesId, uint256 r0,,,) = _createSeries(1 hours, _noEnd(), 4);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BeeefRoundFactory.NotCreatorOrOwner.selector);
        factory.stopSeries(seriesId);

        uint256 before = MockERC20(usd).balanceOf(creator);
        vm.prank(creator);
        factory.stopSeries(seriesId);
        assertEq(MockERC20(usd).balanceOf(creator) - before, ROUND_SEED * 3, "unused seed back to the creator");
        assertFalse(factory.getSeries(seriesId).active);

        // The current round still finishes and settles.
        BeeefRoundFactory.Round memory r = factory.getRound(r0);
        vm.warp(r.endTime);
        _setPrice(feedA, 182e8);
        _setPrice(feedB, 160e8);
        BeeefOracle(r.oracle).finalize();
        factory.settle(r0);
        assertTrue(factory.isSettled(r0));

        vm.expectRevert(BeeefRoundFactory.SeriesNotActive.selector);
        factory.rollover(seriesId);
        vm.prank(creator);
        vm.expectRevert(BeeefRoundFactory.SeriesNotActive.selector);
        factory.stopSeries(seriesId);
    }

    function test_stopSeries_OwnerCanStopAnySeries() public {
        (uint256 seriesId,,,,) = _createSeries(1 hours, _noEnd(), 2);
        vm.prank(admin);
        factory.stopSeries(seriesId);
        assertFalse(factory.getSeries(seriesId).active);
    }

    function test_rollover_PairSwitchedOff_Waits() public {
        (uint256 seriesId, uint256 r0,,,) = _createSeries(1 hours, _noEnd(), 2);
        uint256 pairId = factory.getSeries(seriesId).pairId;
        vm.prank(admin);
        factory.setPairActive(pairId, false);
        vm.warp(factory.getRound(r0).endTime + 5);
        _setPrice(feedA, 181e8);
        _setPrice(feedB, 160e8);
        vm.expectRevert(BeeefRoundFactory.PairPaused.selector);
        factory.rollover(seriesId);
    }

    function test_rollover_RevertsWhen_RoundNotOver() public {
        (uint256 seriesId, uint256 roundId,,,) = _createSeries(1 hours, _noEnd(), 2);
        vm.warp(factory.getRound(roundId).endTime - 1);
        vm.expectRevert(BeeefRoundFactory.RoundNotOver.selector);
        factory.rollover(seriesId);
    }

    function test_rollover_AfterStaleVoid_TakesFreshStart() public {
        (uint256 seriesId, uint256 r0,,,) = _createSeries(1 hours, _noEnd(), 2);
        BeeefRoundFactory.Round memory prev = factory.getRound(r0);
        vm.warp(prev.endTime + SNAPSHOT_WINDOW + 1); // nobody finalized in the end window
        _setPrice(feedA, 190e8);
        _setPrice(feedB, 150e8);
        uint256 r1 = factory.rollover(seriesId);

        assertEq(uint8(BeeefOracle(prev.oracle).outcome()), uint8(BeeefOracle.Outcome.VoidEndMissed));
        BeeefRoundFactory.Round memory next = factory.getRound(r1);
        assertFalse(next.carriedStart);
        assertEq(next.startTime, block.timestamp);
        assertEq(BeeefOracle(next.oracle).startSnapshot().priceA, 190e8, "fresh start snapshot");
    }

    function test_rollover_NextRoundCrossesWeekend_QueuesForTheOpen() public {
        vm.warp(FRIDAY + 22 hours + 30 minutes);
        _setPrice(feedA, 180e8);
        _setPrice(feedB, 160e8);
        (uint256 seriesId,,,,) = _createSeries(1 hours, _noEnd(), 2); // 22:30 -> 23:30 fits
        (, uint256 nextId) = _endAndRoll(seriesId, 10); // 23:30 -> 00:30 would cross Saturday
        BeeefRoundFactory.Round memory next = factory.getRound(nextId);
        assertEq(next.startTime, NEXT_OPEN, "rollover pauses for the weekend");
        assertFalse(next.carriedStart, "fresh start price at the open");
    }

    function test_rollover_Permissionless() public {
        (uint256 seriesId, uint256 roundId,,,) = _createSeries(1 hours, _noEnd(), 2);
        vm.warp(factory.getRound(roundId).endTime + 5);
        _setPrice(feedA, 182e8);
        _setPrice(feedB, 160e8);
        vm.prank(makeAddr("anyone"));
        factory.rollover(seriesId);
    }

    // ==================== Fees ====================

    function test_feeSplitter_PlatformCutThenRecipients() public {
        address platform = makeAddr("platform");
        address charity = makeAddr("charity");
        vm.prank(admin);
        registry.setPlatformFee(platform, 1000); // 10%
        BeeefRoundFactory.FeeSplit memory f;
        f.recipients = new address[](2);
        f.recipients[0] = creator;
        f.recipients[1] = charity;
        f.bps = new uint16[](2);
        f.bps[0] = 7000;
        f.bps[1] = 3000;
        _fund(creator, ROUND_SEED);
        vm.startPrank(creator);
        MockERC20(usd).approve(address(factory), ROUND_SEED);
        (uint256 seriesId,) = factory.createOneOff(stockA, stockB, 1 hours, f, ROUND_SEED);
        vm.stopPrank();

        BeeefFeeSplitter splitter = BeeefFeeSplitter(factory.getSeries(seriesId).feeSplitter);
        _fund(address(splitter), 1000e6);
        uint256 creatorBefore = MockERC20(usd).balanceOf(creator);
        splitter.distribute(usd);
        assertEq(MockERC20(usd).balanceOf(platform), 100e6);
        assertEq(MockERC20(usd).balanceOf(creator) - creatorBefore, 630e6);
        assertEq(MockERC20(usd).balanceOf(charity), 270e6);
        assertEq(MockERC20(usd).balanceOf(address(splitter)), 0);
    }

    // ==================== Clock ====================

    function test_lockTime_MinOf60sAnd10Percent() public view {
        assertEq(registry.lockTimeFor(1000, 1 hours), 1000 + 1 hours - 60);
        assertEq(registry.lockTimeFor(1000, 10 minutes), 1000 + 10 minutes - 60);
        assertEq(registry.lockTimeFor(1000, 5 minutes), 1000 + 5 minutes - 30, "short round: last 10%");
    }

    // ==================== Market hours ====================

    function test_isMarketOpen_WeeklyWindow() public view {
        assertTrue(registry.isMarketOpen(MONDAY + 14 hours, MONDAY + 15 hours), "Monday afternoon");
        assertFalse(registry.isMarketOpen(MONDAY + 30 minutes, MONDAY + 50 minutes), "Monday before 01:00 UTC");
        assertTrue(registry.isMarketOpen(MONDAY + 1 hours, MONDAY + 2 hours), "Monday 01:00 UTC reopen");
        assertTrue(registry.isMarketOpen(FRIDAY + 22 hours, FRIDAY + 23 hours + 59 minutes), "late Friday");
        assertFalse(registry.isMarketOpen(FRIDAY + 23 hours, SATURDAY + 1 minutes), "into Saturday");
        assertFalse(registry.isMarketOpen(SATURDAY + 12 hours, SATURDAY + 13 hours), "Saturday");
        assertFalse(registry.isMarketOpen(SUNDAY + 22 hours, SUNDAY + 23 hours), "Sunday night");
        assertTrue(registry.isMarketOpen(NEXT_MONDAY + 1 hours, NEXT_MONDAY + 1 days), "next Monday to Tuesday");
    }

    function test_nextStart() public view {
        assertEq(registry.nextStart(MONDAY + 14 hours, 1 hours), MONDAY + 14 hours, "open now");
        assertEq(registry.nextStart(SATURDAY + 3 hours, 1 hours), NEXT_OPEN, "weekend");
        assertEq(registry.nextStart(FRIDAY + 23 hours + 30 minutes, 1 hours), NEXT_OPEN, "would cross the close");
        assertEq(registry.nextStart(MONDAY + 30 minutes, 10 minutes), MONDAY + 1 hours, "before Monday open");
    }

    // ==================== Admin ====================

    function test_admin_OnlyOwner() public {
        BeeefRegistry.OracleSettings memory settings = registry.oracleSettings();
        BeeefRegistry.PoolConfig memory pool = registry.poolConfig();
        BeeefRegistry.ClockSettings memory clock = registry.clockSettings();
        _createPair(1 hours);
        vm.startPrank(creator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setStock(stockA, feedA, "X");
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setDuration(2 hours, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setClosedDay(1, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setWeeklyClose(0, 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setMinSeed(0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setOracleSettings(settings);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setPoolConfig(pool);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setClockSettings(clock);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setPairActive(0, false);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setPlatformFee(creator, 100);
        vm.stopPrank();
    }

    function test_admin_PlatformFeeCapped() public {
        vm.prank(admin);
        vm.expectRevert(BeeefRegistry.InvalidPlatformFee.selector);
        registry.setPlatformFee(admin, 2001);
    }

    /// The course fee counts toward the 20% ceiling, so the platform may take at most 20% minus the course bps.
    function test_admin_PlatformFeeCapIncludesCourseFee() public {
        (address courseRecipient, uint16 courseBps) = registry.courseFee();
        assertEq(courseBps, CourseFee.COURSE_FEE_BPS);
        assertEq(courseRecipient, CourseFee.COURSE_FEE_RECIPIENT);
        uint16 maxPlatform = registry.MAX_TOTAL_FEE_BPS() - courseBps;
        vm.prank(admin);
        registry.setPlatformFee(admin, maxPlatform);
        assertEq(registry.platformFeeBps(), maxPlatform);
        vm.prank(admin);
        vm.expectRevert(BeeefRegistry.InvalidPlatformFee.selector);
        registry.setPlatformFee(admin, maxPlatform + 1);
    }

    /// With the placeholder recipient the splitter skips the course cut, so local runs match the platform-only split.
    /// Once `CourseFee.COURSE_FEE_RECIPIENT` is set, `CourseFee.cut` is `COURSE_FEE_BPS / 10_000` of the balance and
    /// comes off first.
    function test_feeSplitter_CourseCutMatchesLibrary() public pure {
        uint256 expected = CourseFee.configured() ? 1000e6 * uint256(CourseFee.COURSE_FEE_BPS) / 10_000 : 0;
        assertEq(CourseFee.cut(1000e6), expected);
    }

    function test_admin_ClockSettingsValidation() public {
        vm.startPrank(admin);
        vm.expectRevert(BeeefRegistry.InvalidClockSettings.selector);
        registry.setClockSettings(BeeefRegistry.ClockSettings({ lockWindow: 60, lockBps: 1000, floorWad: 0 }));
        vm.expectRevert(BeeefRegistry.InvalidClockSettings.selector);
        registry.setClockSettings(BeeefRegistry.ClockSettings({ lockWindow: 60, lockBps: 1000, floorWad: 1.1e18 }));
        registry.setClockSettings(BeeefRegistry.ClockSettings({ lockWindow: 120, lockBps: 1000, floorWad: 0.2e18 }));
        vm.stopPrank();
        (, uint256 roundId,,,) = _createPair(1 hours);
        BeeefRoundFactory.Round memory r = factory.getRound(roundId);
        assertEq(r.lockTime, r.endTime - 120);
        assertEq(r.floorWad, 0.2e18);
    }

    function test_admin_PoolConfigValidation() public {
        BeeefRegistry.PoolConfig memory pool = registry.poolConfig();
        pool.fee = 0;
        vm.prank(admin);
        vm.expectRevert(BeeefRegistry.InvalidPoolConfig.selector);
        registry.setPoolConfig(pool);

        pool.fee = 3000;
        Curve[] memory one = new Curve[](1);
        one[0] = Curve({ tickLower: -322_376, tickUpper: -320_376, numPositions: 20, shares: 1e18 });
        pool.curves = one;
        vm.prank(admin);
        registry.setPoolConfig(pool);
        assertEq(registry.poolConfig().fee, 3000);
        _createPair(1 hours);
    }

    function test_admin_InvalidWeeklyClose() public {
        vm.startPrank(admin);
        vm.expectRevert(BeeefRegistry.InvalidWeeklyClose.selector);
        registry.setWeeklyClose(uint32(7 days), 0);
        vm.expectRevert(BeeefRegistry.InvalidWeeklyClose.selector);
        registry.setWeeklyClose(5, 5);
        vm.stopPrank();
    }

    // ==================== Misc ====================

    function test_unlockCallback_OnlyPoolManager() public {
        vm.expectRevert(BeeefRoundFactory.NotPoolManager.selector);
        factory.unlockCallback("");
    }

    function test_unknownIds_Revert() public {
        vm.expectRevert(BeeefRoundFactory.UnknownRound.selector);
        factory.getRound(0);
        vm.expectRevert(BeeefRoundFactory.UnknownRound.selector);
        factory.roundIdOf(address(1));
        vm.expectRevert(BeeefRoundFactory.UnknownPair.selector);
        factory.getPair(0);
        vm.expectRevert(BeeefRoundFactory.UnknownPair.selector);
        factory.pairIdOf(stockA, stockB);
        vm.expectRevert(BeeefRoundFactory.UnknownSeries.selector);
        factory.getSeries(0);
        vm.expectRevert(BeeefRoundFactory.UnknownSeries.selector);
        factory.rollover(0);
    }
}
