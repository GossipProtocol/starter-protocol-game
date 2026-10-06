import { Outcome, isVoidOutcome } from "./constants.js";

/**
 * The round state machine, shared by the web app, indexer and keeper. The state is always derived from chain data
 * and the clock, never stored, so it cannot drift.
 *
 *   QUEUED -> LIVE -> LOCKED -> AWAITING_FINALIZE -> SETTLING -> CLAIMABLE -> CLOSED
 *                                                 \-> VOID (tie, stale price, missed snapshot)
 */
export type RoundState =
  | "QUEUED" // created while the market was closed; starts at the open
  | "LIVE" // bets open, multiplier 1.00x -> floor
  | "LOCKED" // final minute: no bets, race still running
  | "AWAITING_FINALIZE" // bell rang, result not recorded yet ("Calling it...")
  | "SETTLING" // result recorded, sides still migrating into the pot
  | "CLAIMABLE" // every side settled, winners can claim
  | "VOID" // tie or bad price data
  | "CLOSED"; // all claimed, or the grace period has passed

export interface RoundChainData {
  startTime: bigint;
  lockTime: bigint;
  endTime: bigint;
  finalized: boolean;
  outcome: Outcome;
  migratedA: boolean;
  migratedB: boolean;
  /** Winning supply left unclaimed (0 once everyone claimed). Omit if unknown. */
  unclaimedWinningSupply?: bigint;
}

/** After this long past the bell a claimable round is shown as closed (claims still work on-chain). */
export const CLOSE_GRACE_S = 30n * 86_400n;

export function roundState(r: RoundChainData, now: bigint): RoundState {
  if (now < r.startTime) return "QUEUED";
  if (now < r.lockTime) return "LIVE";
  if (now < r.endTime) return "LOCKED";
  if (!r.finalized) return "AWAITING_FINALIZE";
  if (isVoidOutcome(r.outcome)) return "VOID";
  if (!(r.migratedA && r.migratedB)) return "SETTLING";
  if (r.unclaimedWinningSupply === 0n || now > r.endTime + CLOSE_GRACE_S) return "CLOSED";
  return "CLAIMABLE";
}

/** Sides settled, for the "1 of 2" tracker. */
export const settledCount = (r: Pick<RoundChainData, "migratedA" | "migratedB">) => Number(r.migratedA) + Number(r.migratedB);

export const canBet = (s: RoundState) => s === "LIVE" || s === "QUEUED";
