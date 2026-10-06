import { describe, expect, it } from "vitest";
import vectors from "./vectors.json" with { type: "json" };
import {
  claimAmount,
  isMarketOpen,
  lockTimeFor,
  multiplierAt,
  nextStart,
} from "../src/index.js";

// vectors.json is written by packages/contracts/test/vectors/SdkVectors.t.sol from the real contracts.
const b = (s: string) => BigInt(s);
const clock = { startTime: b(vectors.clock.start), lockTime: b(vectors.clock.lock), floorWad: b(vectors.clock.floor) };

describe("sdk matches the contracts", () => {
  it("multiplier = BeeefClockHook.multiplierAt at every sample", () => {
    for (const v of vectors.multiplier) expect(multiplierAt(clock, b(v.t))).toBe(b(v.m));
  });

  it("lock time = BeeefRoundFactory.lockTimeFor", () => {
    for (const v of vectors.lockTimes) {
      expect(lockTimeFor(b(v.start), b(v.duration), { lockWindow: 60n, lockBps: 1000n })).toBe(b(v.lock));
    }
  });

  it("market calendar = factory isMarketOpen / nextStart", () => {
    const w = Number(vectors.snapshotWindow);
    for (const v of vectors.calendar) {
      const t = Number(v.t);
      expect(isMarketOpen(t, t + 3600), `open @${t}`).toBe(v.open1h);
      expect(nextStart(t, 600, w), `next10m @${t}`).toBe(Number(v.next10m));
      expect(nextStart(t, 86_400, w), `next1d @${t}`).toBe(Number(v.next1d));
    }
  });

  it("claim = PredictionMigrator.claim for a real round", () => {
    const { pot, claimableSupply, claims } = vectors.round;
    for (const c of claims) expect(claimAmount(b(c.tokens), b(pot), b(claimableSupply))).toBe(b(c.out));
  });
});
