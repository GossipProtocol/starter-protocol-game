import { WAD } from "./constants.js";

export interface Clock {
  startTime: bigint;
  lockTime: bigint;
  floorWad: bigint;
}

/**
 * Share multiplier (WAD) a buy gets at time `t`. Mirrors BeeefClockHook._multiplier exactly, including integer
 * rounding: m(t) = 1 - (1 - floor) * (t - start) / (lock - start), clamped to [floor, 1].
 */
export function multiplierAt(c: Clock, t: bigint): bigint {
  if (t <= c.startTime) return WAD;
  if (t >= c.lockTime) return c.floorWad;
  return WAD - ((WAD - c.floorWad) * (t - c.startTime)) / (c.lockTime - c.startTime);
}

/** Tokens the buyer keeps and the tokens the hook withholds for a buy that produced `tokensOut` at time `t`. */
export function applyMultiplier(c: Clock, tokensOut: bigint, t: bigint): { toBuyer: bigint; withheld: bigint; m: bigint } {
  const m = multiplierAt(c, t);
  const toBuyer = (tokensOut * m) / WAD;
  return { toBuyer, withheld: tokensOut - toBuyer, m };
}

export interface ClockSettings {
  lockWindow: bigint;
  lockBps: bigint;
}

/** Mirrors BeeefRoundFactory.lockTimeFor: lock = end - min(lockWindow, duration * lockBps / 10_000). */
export function lockTimeFor(start: bigint, duration: bigint, s: ClockSettings): bigint {
  const byPct = (duration * s.lockBps) / 10_000n;
  const len = byPct < s.lockWindow ? byPct : s.lockWindow;
  return start + duration - len;
}

/** "0.62x" style label. */
export function formatMultiplier(m: bigint, digits = 2): string {
  return `${(Number((m * 10_000n) / WAD) / 10_000).toFixed(digits)}x`;
}
