// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console } from "forge-std/console.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { BeeefClockHook } from "src/BeeefClockHook.sol";
import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { LocalDopplerSetup } from "test/utils/LocalDopplerSetup.sol";

contract BeeefClockHookTest is LocalDopplerSetup {
    uint256 internal roundId;
    BeeefOracle internal oracle;
    address internal entryA;
    address internal entryB;
    BeeefRoundFactory.Round internal r;

    function setUp() public override {
        super.setUp();
        (, roundId, oracle, entryA, entryB) = _createPair(1 hours);
        r = factory.getRound(roundId);
    }

    function tryBuyExactOutExternal(address entry, address buyer, uint256 tokensOut, uint256 maxIn) external {
        _tryBuyExactOut(entry, buyer, tokensOut, maxIn);
    }

    function buyExternal(address entry, address buyer, uint256 amount) external returns (uint256) {
        return _buy(entry, buyer, amount);
    }

    // ==================== Rules ====================

    function test_SellsAlwaysRevert() public {
        _fund(alice, 10e6);
        uint256 tokens = _buy(entryA, alice, 10e6);
        vm.expectRevert();
        this.trySellExternal(entryA, alice, tokens / 2);

        vm.warp(r.lockTime + 1);
        vm.expectRevert();
        this.trySellExternal(entryA, alice, tokens / 2);
    }

    function test_BuysRevertFromTheLock() public {
        _fund(alice, 20e6);
        vm.warp(r.lockTime - 1);
        assertGt(_buy(entryA, alice, 10e6), 0, "last second before the lock is fine");
        vm.warp(r.lockTime);
        vm.expectRevert();
        this.buyExternal(entryA, alice, 10e6);
    }

    function test_TokenAmountBuysRevert() public {
        _fund(alice, 100e6);
        vm.expectRevert();
        this.tryBuyExactOutExternal(entryA, alice, 1000 ether, 100e6);
    }

    function test_OnlyInitializerCanCall() public {
        PoolKey memory key = factory.poolKeyOf(entryA);
        vm.expectRevert(BeeefClockHook.SenderNotInitializer.selector);
        clockHook.onInitialization(entryA, key, abi.encode(uint64(1), uint64(2), uint64(1e17)));
        vm.expectRevert(BeeefClockHook.SenderNotInitializer.selector);
        clockHook.onSwap(address(this), key, IPoolManager.SwapParams(false, -1, 0), BalanceDelta.wrap(0), "");
    }

    // ==================== Multiplier ====================

    function test_Multiplier_StartMidLock() public view {
        uint256 mid = r.startTime + (r.lockTime - r.startTime) / 2;
        assertEq(clockHook.multiplierAt(entryA, r.startTime), 1e18, "1.00x at the start");
        assertEq(clockHook.multiplierAt(entryA, mid), 0.55e18, "0.55x at the midpoint");
        assertEq(clockHook.multiplierAt(entryA, r.lockTime), 0.1e18, "exactly 0.10x at the lock");
        assertEq(clockHook.multiplierAt(entryA, r.startTime - 100), 1e18, "clamped before the start");
        assertEq(clockHook.multiplierAt(entryA, r.lockTime + 100), 0.1e18, "clamped after the lock");
    }

    function testFuzz_Multiplier_MonotonicAndBounded(uint256 t1, uint256 t2) public view {
        t1 = bound(t1, r.startTime, r.lockTime);
        t2 = bound(t2, t1, r.lockTime);
        uint256 m1 = clockHook.multiplierAt(entryA, t1);
        uint256 m2 = clockHook.multiplierAt(entryA, t2);
        assertLe(m2, m1);
        assertGe(m2, 0.1e18);
        assertLe(m1, 1e18);
    }

    /// Buyer receives tokensOut * m(t); the rest goes to the migrator, never to the buyer or the hook.
    function test_BuyerGetsMultipliedShare_HookHoldsNothing() public {
        uint256 mid = r.startTime + (r.lockTime - r.startTime) / 2;
        vm.warp(mid);
        _fund(alice, 10e6);
        uint256 sinkBefore = MockERC20(entryA).balanceOf(address(migrator));
        uint256 got = _buy(entryA, alice, 10e6);
        uint256 withheld = MockERC20(entryA).balanceOf(address(migrator)) - sinkBefore;
        assertGt(withheld, 0);
        // got / (got + withheld) == 0.55 up to rounding
        assertApproxEqRel(got * 1e18 / (got + withheld), 0.55e18, 1e12);
        assertEq(MockERC20(entryA).balanceOf(address(clockHook)), 0, "hook holds zero asset");
        assertEq(MockERC20(usd).balanceOf(address(clockHook)), 0, "hook holds zero USD");
    }

    function testFuzz_HookHoldsZeroAfterEverySwap(uint256 amount, uint256 at) public {
        amount = bound(amount, 1e6, 5000e6);
        at = bound(at, r.startTime, r.lockTime - 1);
        vm.warp(at);
        _fund(alice, amount);
        _buy(entryA, alice, amount);
        assertEq(MockERC20(entryA).balanceOf(address(clockHook)), 0);
        assertEq(MockERC20(entryB).balanceOf(address(clockHook)), 0);
        assertEq(MockERC20(usd).balanceOf(address(clockHook)), 0);
    }

    // ==================== Economics ====================

    /// A $10 bet at the start pays about 5x a $10 bet placed 90% of the way to the lock (m = 0.19).
    function test_EarlyBetPaysAbout5xLateBet() public {
        _fund(alice, 10e6);
        _fund(bob, 10e6);
        uint256 early = _buy(entryA, alice, 10e6);
        vm.warp(r.startTime + (r.lockTime - r.startTime) * 9 / 10);
        uint256 late = _buy(entryA, bob, 10e6);

        vm.warp(r.endTime);
        _setPrice(feedA, oracle.startSnapshot().priceA * 102 / 100);
        _setPrice(feedB, oracle.startSnapshot().priceB);
        oracle.finalize();
        factory.settle(roundId);

        uint256 aliceOut = _claim(address(oracle), entryA, alice, early);
        uint256 bobOut = _claim(address(oracle), entryA, bob, late);
        uint256 ratioX100 = aliceOut * 100 / bobOut;
        console.log("early / late payout x100", ratioX100);
        assertGe(ratioX100, 480);
        assertLe(ratioX100, 560);
    }

    /// Withheld tokens never count as winning supply, and the full USD stake reaches the pot.
    function test_WithheldTokensExcludedFromClaimableSupply() public {
        vm.warp(r.startTime + 30 minutes);
        _fund(alice, 100e6);
        uint256 got = _buy(entryA, alice, 100e6);
        uint256 withheld = MockERC20(entryA).balanceOf(address(migrator));
        assertGt(withheld, 0);

        vm.warp(r.endTime);
        _setPrice(feedA, oracle.startSnapshot().priceA * 102 / 100);
        _setPrice(feedB, oracle.startSnapshot().priceB);
        oracle.finalize();
        factory.settle(roundId);

        uint256 claimable = migrator.getEntry(address(oracle), factory.ENTRY_ID_A()).claimableSupply;
        uint256 held = got + MockERC20(entryA).balanceOf(creator);
        uint256 dust = MockERC20(entryA).balanceOf(address(manager)) + MockERC20(entryA).balanceOf(address(0xdead));
        assertEq(claimable, held + dust);
        uint256 grossIn = 100e6 + 2 * SEED;
        assertApproxEqAbs(migrator.getMarket(address(oracle)).totalPot, grossIn - grossIn * FEE / 1e6, 100);
    }
}
