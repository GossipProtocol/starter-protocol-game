import { describe, expect, it } from "vitest";
import {
  Outcome,
  WAD,
  applyMultiplier,
  estimatePayout,
  formatMove,
  formatMultiplier,
  leader,
  marketSession,
  multiplierAt,
  pctMove,
  quoteBuy,
  roundState,
  settledCount,
  type RoundChainData,
} from "../src/index.js";

const clock = { startTime: 1000n, lockTime: 2000n, floorWad: WAD / 10n };

describe("multiplier", () => {
  it("1.00x at the start, 0.55x at the midpoint, exactly 0.10x at the lock", () => {
    expect(multiplierAt(clock, 1000n)).toBe(WAD);
    expect(multiplierAt(clock, 1500n)).toBe((WAD * 55n) / 100n);
    expect(multiplierAt(clock, 2000n)).toBe(WAD / 10n);
    expect(formatMultiplier(multiplierAt(clock, 1420n))).toBe("0.62x");
  });
  it("splits a buy into kept and withheld tokens", () => {
    const { toBuyer, withheld } = applyMultiplier(clock, 1000n, 1500n);
    expect(toBuyer).toBe(550n);
    expect(withheld).toBe(450n);
  });
});

describe("moves", () => {
  it("higher % move wins; down 5% beats down 6%", () => {
    expect(leader(100n, 120n, 100n, 112n)).toBe("A");
    expect(leader(100n, 80n, 100n, 105n)).toBe("B");
    expect(leader(100n, 95n, 100n, 94n)).toBe("A");
    expect(leader(300_000_000n, 300_000_003n, 700_000_000n, 700_000_007n)).toBe("TIE");
  });
  it("formats like the UI", () => {
    expect(pctMove(22_902_739_517n, 23_323_000_000n)).toBeCloseTo(1.835, 2);
    expect(formatMove(-0.35)).toBe("▼ 0.35%");
    expect(formatMove(1.84)).toBe("▲ 1.84%");
  });
});

describe("quote + estimate", () => {
  it("a start bet gets ~5.26x the tokens of a bet at 90% (flat curve)", () => {
    const price = { num: 10_000n, den: 10n ** 18n }; // $0.01 per token (6-dec USD, 18-dec token)
    const early = quoteBuy({ usdcIn: 10_000_000n, lpFeePpm: 10_000n, price, multiplier: multiplierAt(clock, 1000n) });
    const late = quoteBuy({ usdcIn: 10_000_000n, lpFeePpm: 10_000n, price, multiplier: multiplierAt(clock, 1900n) });
    expect(Number((early.tokensToBuyer * 100n) / late.tokensToBuyer)).toBe(526);
    expect(early.tokensGross).toBe(990n * 10n ** 18n); // $9.90 after the 1% fee at $0.01
  });
  it("estimate = your share of the pot after your bet", () => {
    const est = estimatePayout({ usdcIn: 100n, tokensToBuyer: 100n, sideSupply: 100n, pot: 300n, lpFeePpm: 0n });
    expect(est).toBe(200n); // half of $400
  });
});

describe("round state machine", () => {
  const base: RoundChainData = {
    startTime: 100n,
    lockTime: 1840n,
    endTime: 1900n,
    finalized: false,
    outcome: Outcome.Pending,
    migratedA: false,
    migratedB: false,
  };
  it("walks QUEUED -> LIVE -> LOCKED -> AWAITING_FINALIZE", () => {
    expect(roundState(base, 50n)).toBe("QUEUED");
    expect(roundState(base, 100n)).toBe("LIVE");
    expect(roundState(base, 1839n)).toBe("LIVE");
    expect(roundState(base, 1840n)).toBe("LOCKED");
    expect(roundState(base, 1900n)).toBe("AWAITING_FINALIZE");
  });
  it("SETTLING until both sides migrate, then CLAIMABLE, then CLOSED", () => {
    const fin = { ...base, finalized: true, outcome: Outcome.WinnerA };
    expect(roundState(fin, 2000n)).toBe("SETTLING");
    expect(settledCount({ ...fin, migratedA: true })).toBe(1);
    expect(roundState({ ...fin, migratedA: true }, 2000n)).toBe("SETTLING");
    expect(roundState({ ...fin, migratedA: true, migratedB: true }, 2000n)).toBe("CLAIMABLE");
    expect(roundState({ ...fin, migratedA: true, migratedB: true, unclaimedWinningSupply: 0n }, 2000n)).toBe("CLOSED");
  });
  it("VOID on ties and bad data", () => {
    for (const o of [Outcome.VoidTie, Outcome.VoidStartMissed, Outcome.VoidEndMissed]) {
      expect(roundState({ ...base, finalized: true, outcome: o }, 2000n)).toBe("VOID");
    }
  });
});

describe("market session", () => {
  it("closed on Saturday, next open Monday 01:00 UTC", () => {
    const saturdayNoon = 1_789_948_800 + 5 * 86_400 + 12 * 3600;
    expect(marketSession(saturdayNoon, 300)).toEqual({ open: false, nextOpen: 1_789_948_800 + 7 * 86_400 + 3600 });
  });
});
