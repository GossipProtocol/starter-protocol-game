// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibClone } from "@solady/utils/LibClone.sol";
import { Test } from "forge-std/Test.sol";

import { BeeefOracle } from "src/BeeefOracle.sol";
import { MockSequencerFeed } from "test/mocks/MockSequencerFeed.sol";
import { MockStockToken } from "test/mocks/MockStockToken.sol";
import { MockV3Aggregator } from "test/mocks/MockV3Aggregator.sol";

contract BeeefOracleTest is Test {
    BeeefOracle internal implementation;
    BeeefOracle internal oracle;
    MockV3Aggregator internal feedA;
    MockV3Aggregator internal feedB;
    MockStockToken internal stockA;
    MockStockToken internal stockB;

    address internal registrar = makeAddr("registrar");
    address internal entryA = makeAddr("entryA");
    address internal entryB = makeAddr("entryB");
    address internal entryVoid = makeAddr("entryVoid");

    uint64 internal constant START = 1_790_000_000;
    uint64 internal constant END = START + 1 hours;
    uint32 internal constant WINDOW = 5 minutes;
    uint32 internal constant STALENESS = 1 days;

    function setUp() public {
        vm.warp(START - 10 minutes);
        implementation = new BeeefOracle();
        feedA = new MockV3Aggregator(8, 100e8); // $100
        feedB = new MockV3Aggregator(8, 50e8); // $50
        stockA = new MockStockToken();
        stockB = new MockStockToken();
        oracle = _clone(_config(false), entryVoid);
    }

    // ==================== Helpers ====================

    function _config(bool applyMultiplier) internal view returns (BeeefOracle.Config memory) {
        return BeeefOracle.Config({
            feedA: address(feedA),
            feedB: address(feedB),
            stockA: address(stockA),
            stockB: address(stockB),
            startTime: START,
            endTime: END,
            snapshotWindow: WINDOW,
            maxStaleness: STALENESS,
            sequencerFeed: address(0),
            sequencerGracePeriod: 0,
            applyMultiplier: applyMultiplier
        });
    }

    function _clone(BeeefOracle.Config memory c, address void_) internal returns (BeeefOracle o) {
        o = BeeefOracle(LibClone.clone(address(implementation)));
        o.initialize(c, registrar);
        vm.prank(registrar);
        o.setEntries(entryA, entryB, void_);
    }

    function _start(BeeefOracle o) internal {
        vm.warp(START);
        o.snapshotStart();
    }

    function _finalizeWith(BeeefOracle o, int256 endA, int256 endB) internal {
        vm.warp(END);
        feedA.updateAnswer(endA);
        feedB.updateAnswer(endB);
        o.finalize();
    }

    function _assertWinner(BeeefOracle o, address expected, BeeefOracle.Outcome outcome) internal view {
        (address w, bool fin) = o.getWinner(address(o));
        assertTrue(fin, "finalized");
        assertEq(w, expected, "winner");
        assertEq(uint8(o.outcome()), uint8(outcome), "outcome");
    }

    // ==================== Resolution ====================

    function test_AWins() public {
        _start(oracle);
        _finalizeWith(oracle, 102e8, 50.5e8); // A +2%, B +1%
        _assertWinner(oracle, entryA, BeeefOracle.Outcome.WinnerA);
        assertEq(oracle.moveA(), 1.02e18);
        assertEq(oracle.moveB(), 1.01e18);
        assertFalse(oracle.isVoid());
    }

    function test_BWins() public {
        _start(oracle);
        _finalizeWith(oracle, 99e8, 49.75e8); // A -1%, B -0.5%
        _assertWinner(oracle, entryB, BeeefOracle.Outcome.WinnerB);
    }

    function test_BothDown_SmallerLossWins() public {
        _start(oracle);
        _finalizeWith(oracle, 90e8, 49e8); // A -10%, B -2%
        _assertWinner(oracle, entryB, BeeefOracle.Outcome.WinnerB);
    }

    function test_ExactTie_IsVoid() public {
        _start(oracle);
        _finalizeWith(oracle, 110e8, 55e8); // both +10%
        _assertWinner(oracle, entryVoid, BeeefOracle.Outcome.VoidTie);
        assertTrue(oracle.isVoid());
    }

    function test_NoPriceChange_IsVoidTie() public {
        _start(oracle);
        vm.warp(END);
        // Feeds did not update (common for push feeds with a 0.5% deviation threshold) but are within staleness.
        oracle.finalize();
        _assertWinner(oracle, entryVoid, BeeefOracle.Outcome.VoidTie);
    }

    function test_TieDetection_IsExact_NotRoundedWad() public {
        // Ratios are compared exactly (cross multiplication), not through the truncated WAD moves.
        feedA.updateAnswer(3e8);
        feedB.updateAnswer(7e8);
        BeeefOracle o = _clone(_config(false), entryVoid);
        _start(o);
        // A: 3e8 -> 3e8 + 3 and B: 7e8 -> 7e8 + 7 are both exactly +1e-8.
        vm.warp(END);
        feedA.updateAnswer(3e8 + 3);
        feedB.updateAnswer(7e8 + 7);
        o.finalize();
        _assertWinner(o, entryVoid, BeeefOracle.Outcome.VoidTie);

        BeeefOracle o2 = _clone(_config(false), entryVoid);
        vm.warp(START);
        feedA.updateAnswer(3e8);
        feedB.updateAnswer(7e8);
        o2.snapshotStart();
        vm.warp(END);
        feedA.updateAnswer(3e8 + 3);
        feedB.updateAnswer(7e8 + 6); // B moved 6/7e8 < 1e-8 relative, A moved 1e-8
        o2.finalize();
        _assertWinner(o2, entryA, BeeefOracle.Outcome.WinnerA);
    }

    function test_DifferentFeedDecimals() public {
        MockV3Aggregator f18 = new MockV3Aggregator(18, 100e18);
        BeeefOracle.Config memory c = _config(false);
        c.feedB = address(f18);
        BeeefOracle o = _clone(c, entryVoid);
        _start(o);
        vm.warp(END);
        feedA.updateAnswer(101e8); // +1%
        f18.updateAnswer(101.5e18); // +1.5%
        o.finalize();
        _assertWinner(o, entryB, BeeefOracle.Outcome.WinnerB);
    }

    // ==================== Voiding ====================

    function test_StaleStart_Reverts_ThenVoid() public {
        feedA.updateAnswerAt(100e8, START - STALENESS - 1);
        vm.warp(START);
        vm.expectRevert(abi.encodeWithSelector(BeeefOracle.StalePrice.selector, address(feedA), START - STALENESS - 1));
        oracle.snapshotStart();

        vm.warp(END);
        oracle.finalize();
        _assertWinner(oracle, entryVoid, BeeefOracle.Outcome.VoidStartMissed);
    }

    function test_StaleStart_RecoversInsideWindow() public {
        feedA.updateAnswerAt(100e8, START - STALENESS - 1);
        vm.warp(START);
        vm.expectRevert();
        oracle.snapshotStart();
        vm.warp(START + 1 minutes);
        feedA.updateAnswer(100e8); // heartbeat arrives
        oracle.snapshotStart();
        _finalizeWith(oracle, 101e8, 50e8);
        _assertWinner(oracle, entryA, BeeefOracle.Outcome.WinnerA);
    }

    function test_StaleEnd_Reverts_ThenVoidAfterWindow() public {
        _start(oracle);
        vm.warp(END);
        feedA.updateAnswer(101e8);
        feedB.updateAnswerAt(50e8, END - STALENESS - 1);
        vm.expectRevert(abi.encodeWithSelector(BeeefOracle.StalePrice.selector, address(feedB), END - STALENESS - 1));
        oracle.finalize();
        assertFalse(oracle.finalized());

        vm.warp(END + WINDOW + 1);
        oracle.finalize();
        _assertWinner(oracle, entryVoid, BeeefOracle.Outcome.VoidEndMissed);
    }

    function test_MissedStart_IsVoid() public {
        vm.warp(START + WINDOW + 1);
        vm.expectRevert(BeeefOracle.OutsideStartWindow.selector);
        oracle.snapshotStart();

        vm.warp(END);
        oracle.finalize();
        _assertWinner(oracle, entryVoid, BeeefOracle.Outcome.VoidStartMissed);
    }

    function test_MissedEndWindow_IsVoid_EvenWithFreshPrices() public {
        _start(oracle);
        vm.warp(END + WINDOW + 1);
        feedA.updateAnswer(200e8);
        oracle.finalize();
        _assertWinner(oracle, entryVoid, BeeefOracle.Outcome.VoidEndMissed);
    }

    function test_SnapshotBeforeStart_Reverts() public {
        vm.warp(START - 1);
        vm.expectRevert(BeeefOracle.OutsideStartWindow.selector);
        oracle.snapshotStart();
    }

    function test_InvalidAnswer_Reverts() public {
        feedA.updateAnswer(0);
        vm.warp(START);
        vm.expectRevert(abi.encodeWithSelector(BeeefOracle.InvalidAnswer.selector, address(feedA)));
        oracle.snapshotStart();

        feedA.updateAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(BeeefOracle.InvalidAnswer.selector, address(feedA)));
        oracle.snapshotStart();
    }

    function test_IncompleteRound_Reverts() public {
        vm.warp(START);
        feedA.setRoundData(10, 100e8, block.timestamp, 9);
        vm.expectRevert(abi.encodeWithSelector(BeeefOracle.IncompleteRound.selector, address(feedA)));
        oracle.snapshotStart();
    }

    function test_FutureUpdatedAt_Reverts() public {
        vm.warp(START);
        feedA.updateAnswerAt(100e8, START + 1);
        vm.expectRevert(abi.encodeWithSelector(BeeefOracle.StalePrice.selector, address(feedA), START + 1));
        oracle.snapshotStart();
    }

    function test_OraclePausedStock_Reverts() public {
        stockB.setOraclePaused(true);
        vm.warp(START);
        vm.expectRevert(abi.encodeWithSelector(BeeefOracle.FeedPaused.selector, address(stockB)));
        oracle.snapshotStart();
    }

    function test_SequencerDown_Reverts() public {
        MockSequencerFeed seq = new MockSequencerFeed(START - 2 hours);
        BeeefOracle.Config memory c = _config(false);
        c.sequencerFeed = address(seq);
        c.sequencerGracePeriod = 1 hours;
        BeeefOracle o = _clone(c, entryVoid);

        vm.warp(START);
        seq.set(1, START - 10);
        vm.expectRevert(BeeefOracle.SequencerDown.selector);
        o.snapshotStart();

        seq.set(0, START - 10); // back up but still in grace period
        vm.expectRevert(BeeefOracle.SequencerDown.selector);
        o.snapshotStart();

        seq.set(0, START - 2 hours);
        o.snapshotStart();
    }

    function test_Void_WithoutVoidEntry_WinnerIsZero() public {
        BeeefOracle o = _clone(_config(false), address(0));
        vm.warp(END);
        o.finalize();
        (address w, bool fin) = o.getWinner(address(o));
        assertEq(w, address(0));
        assertTrue(fin);
        assertTrue(o.isVoid());
    }

    // ==================== Multiplier ====================

    /// Robinhood feeds already publish price * uiMultiplier. A multiplier bump mid round is visible in the feed
    /// answer and must not be applied a second time.
    function test_Multiplier_RobinhoodFeed_NotDoubleCounted() public {
        _start(oracle);
        vm.warp(END);
        // A: share price flat, a 5% reinvested dividend bumps the multiplier 1.0 -> 1.05 and the feed
        // (share price * multiplier) shows +5% total return. B: +4% price move, no corporate action.
        stockA.setMultiplier(1.05e18);
        feedA.updateAnswer(105e8);
        feedB.updateAnswer(52e8);
        oracle.finalize();
        _assertWinner(oracle, entryA, BeeefOracle.Outcome.WinnerA);
        assertEq(oracle.moveA(), 1.05e18, "feed price used as is");
    }

    /// With a raw share-price feed, applyMultiplier = true turns a 10:1 split mid round into the correct total return
    /// instead of a -90% move.
    function test_Multiplier_SplitMidRound_DoesNotFlip() public {
        BeeefOracle o = _clone(_config(true), entryVoid);
        _start(o);
        vm.warp(END);
        stockA.setMultiplier(10e18); // 10:1 split, raw share price drops 10x
        feedA.updateAnswer(10.2e8); // +2% real move
        feedB.updateAnswer(50.5e8); // +1%
        o.finalize();
        _assertWinner(o, entryA, BeeefOracle.Outcome.WinnerA);
        assertEq(o.moveA(), 1.02e18);
        assertEq(o.startSnapshot().multA, 1e18);
        assertEq(o.endSnapshot().multA, 10e18);
    }

    // ==================== Lifecycle guards ====================

    function test_DoubleFinalize_Reverts() public {
        _start(oracle);
        _finalizeWith(oracle, 101e8, 50e8);
        vm.expectRevert(BeeefOracle.AlreadyFinalized.selector);
        oracle.finalize();
    }

    function test_FinalizeBeforeEnd_Reverts() public {
        _start(oracle);
        vm.warp(END - 1);
        vm.expectRevert(BeeefOracle.TooEarly.selector);
        oracle.finalize();
    }

    function test_DoubleStart_Reverts() public {
        _start(oracle);
        vm.expectRevert(BeeefOracle.StartAlreadyTaken.selector);
        oracle.snapshotStart();
    }

    function test_NotFinalized_BeforeResolution() public view {
        (address w, bool fin) = oracle.getWinner(address(oracle));
        assertEq(w, address(0));
        assertFalse(fin);
    }

    function test_Implementation_CannotBeInitialized() public {
        vm.expectRevert(BeeefOracle.AlreadyInitialized.selector);
        implementation.initialize(_config(false), registrar);
    }

    function test_Clone_CannotBeReinitialized() public {
        vm.expectRevert(BeeefOracle.AlreadyInitialized.selector);
        oracle.initialize(_config(false), registrar);
    }

    function test_SetEntries_OnlyRegistrar_Once() public {
        BeeefOracle o = BeeefOracle(LibClone.clone(address(implementation)));
        o.initialize(_config(false), registrar);
        vm.expectRevert(BeeefOracle.NotRegistrar.selector);
        o.setEntries(entryA, entryB, entryVoid);

        vm.startPrank(registrar);
        vm.expectRevert(BeeefOracle.InvalidEntries.selector);
        o.setEntries(entryA, entryA, entryVoid);
        o.setEntries(entryA, entryB, entryVoid);
        vm.expectRevert(BeeefOracle.EntriesAlreadySet.selector);
        o.setEntries(entryA, entryB, entryVoid);
        vm.stopPrank();
    }

    function test_SnapshotBeforeEntries_Reverts() public {
        BeeefOracle o = BeeefOracle(LibClone.clone(address(implementation)));
        o.initialize(_config(false), registrar);
        vm.warp(START);
        vm.expectRevert(BeeefOracle.EntriesNotSet.selector);
        o.snapshotStart();
    }

    function test_InvalidConfig_Reverts() public {
        BeeefOracle.Config memory c = _config(false);
        c.endTime = c.startTime;
        BeeefOracle o = BeeefOracle(LibClone.clone(address(implementation)));
        vm.expectRevert(BeeefOracle.InvalidConfig.selector);
        o.initialize(c, registrar);
    }

    // ==================== Fuzz ====================

    /// The winner always matches the higher exact ratio; equal ratios always void.
    function testFuzz_WinnerMatchesHigherMove(uint64 sA, uint64 sB, uint64 eA, uint64 eB) public {
        sA = uint64(bound(sA, 1, 1e14));
        sB = uint64(bound(sB, 1, 1e14));
        eA = uint64(bound(eA, 1, 1e14));
        eB = uint64(bound(eB, 1, 1e14));
        feedA.updateAnswer(int256(uint256(sA)));
        feedB.updateAnswer(int256(uint256(sB)));
        BeeefOracle o = _clone(_config(false), entryVoid);
        _start(o);
        _finalizeWith(o, int256(uint256(eA)), int256(uint256(eB)));

        uint256 l = uint256(eA) * sB;
        uint256 r = uint256(eB) * sA;
        (address w,) = o.getWinner(address(o));
        if (l > r) assertEq(w, entryA);
        else if (r > l) assertEq(w, entryB);
        else assertEq(w, entryVoid);
    }
}
