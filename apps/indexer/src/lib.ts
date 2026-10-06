import type { Context } from "ponder:registry";
import { playerStats } from "ponder:schema";
import type { Address } from "viem";

export type Db = Context["db"];

export const lc = (a: Address) => a.toLowerCase() as Address;

export const eventId = (event: { transaction: { hash: string }; log: { logIndex: number } }) =>
  `${event.transaction.hash}-${event.log.logIndex}`;

/** Matches a bet to the Transfer that delivers its tokens. */
export const pendingKey = (txHash: string, entry: Address, tokens: bigint) => `${txHash}-${lc(entry)}-${tokens}`;

export async function ensurePlayer(db: Db, address: Address) {
  await db
    .insert(playerStats)
    .values({
      address,
      roundsPlayed: 0,
      bets: 0,
      wins: 0,
      losses: 0,
      voids: 0,
      usdWagered: 0n,
      usdWon: 0n,
      currentStreak: 0,
      bestStreak: 0,
    })
    .onConflictDoNothing();
}
