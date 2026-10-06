import { ponder } from "ponder:registry";
import { buys, entries, pendingBuys, playerStats, positions, roundPlayers, rounds } from "ponder:schema";
import type { Address } from "viem";

import { known } from "./deployment";
import { type Db, ensurePlayer, eventId, lc, pendingKey } from "./lib";

ponder.on("BeeefClockHook:ClockBuy", async ({ event, context }) => {
  const { db } = context;
  const a = event.args;
  const entry = lc(a.asset);
  const id = eventId(event);
  const isSeed = lc(a.sender) === known.factory;

  const e = await db
    .insert(entries)
    .values({ address: entry, usdIn: a.numeraireIn, tokensSold: a.tokensToBuyer, tokensWithheld: a.tokensWithheld })
    .onConflictDoUpdate((row) => ({
      usdIn: row.usdIn + a.numeraireIn,
      tokensSold: row.tokensSold + a.tokensToBuyer,
      tokensWithheld: row.tokensWithheld + a.tokensWithheld,
    }));
  if (isSeed && !e.seedBuyId) await db.update(entries, { address: entry }).set({ seedBuyId: id });

  await db.insert(buys).values({
    id,
    entry,
    roundId: e.roundId,
    side: e.side,
    isSeed,
    usdIn: a.numeraireIn,
    tokensToBuyer: a.tokensToBuyer,
    tokensWithheld: a.tokensWithheld,
    multiplierWad: a.multiplierWad,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  });

  // Seeds land before RoundCreated, which totals them. Bets update the round here.
  if (e.roundId !== null) {
    const isA = e.side === "A";
    await db.update(rounds, { id: e.roundId }).set((r) => ({
      potA: isA ? r.potA + a.numeraireIn : r.potA,
      potB: isA ? r.potB : r.potB + a.numeraireIn,
      totalPotUsd: r.totalPotUsd + a.numeraireIn,
      seedUsd: isSeed ? r.seedUsd + a.numeraireIn : r.seedUsd,
      bets: isSeed ? r.bets : r.bets + 1,
    }));
  }
  if (!isSeed) {
    await db
      .insert(pendingBuys)
      .values({ id: pendingKey(event.transaction.hash, entry, a.tokensToBuyer), buyId: id })
      .onConflictDoNothing();
  }
});

async function onTransfer(
  db: Db,
  event: {
    args: { from: Address; to: Address; value: bigint };
    log: { address: Address };
    transaction: { hash: `0x${string}` };
    block: { timestamp: bigint };
  },
) {
  const entry = lc(event.log.address);
  const from = lc(event.args.from);
  const to = lc(event.args.to);
  const value = event.args.value;
  const zero = "0x0000000000000000000000000000000000000000";

  if (from !== zero) {
    await db.update(positions, { entry, holder: from }).set((p) => ({ balance: p.balance - value }));
  }
  if (to !== zero) {
    await db
      .insert(positions)
      .values({ entry, holder: to, balance: value })
      .onConflictDoUpdate((p) => ({ balance: p.balance + value }));
  }

  // A bet's tokens leave the PoolManager for the player; the withheld share goes to the migrator.
  if (from !== known.poolManager || to === known.migrator) return;
  const key = pendingKey(event.transaction.hash, entry, value);
  const pending = await db.find(pendingBuys, { id: key });
  if (!pending) return;
  await db.delete(pendingBuys, { id: key });
  await recordBet(db, pending.buyId, to, event.block.timestamp);
}

ponder.on("EntryA:Transfer", ({ event, context }) => onTransfer(context.db, event));
ponder.on("EntryB:Transfer", ({ event, context }) => onTransfer(context.db, event));

/** Attributes a bet to `player` and updates their round and lifetime stats. */
export async function recordBet(db: Db, buyId: string, player: Address, timestamp: bigint) {
  const buy = await db.update(buys, { id: buyId }).set({ buyer: player });
  if (buy.roundId === null) return;
  const isA = buy.side === "A";

  const existing = await db.find(roundPlayers, { roundId: buy.roundId, player });
  if (existing) {
    await db.update(roundPlayers, { roundId: buy.roundId, player }).set((rp) => ({
      usdA: isA ? rp.usdA + buy.usdIn : rp.usdA,
      usdB: isA ? rp.usdB : rp.usdB + buy.usdIn,
      tokensA: isA ? rp.tokensA + buy.tokensToBuyer : rp.tokensA,
      tokensB: isA ? rp.tokensB : rp.tokensB + buy.tokensToBuyer,
    }));
  } else {
    await db.insert(roundPlayers).values({
      roundId: buy.roundId,
      player,
      usdA: isA ? buy.usdIn : 0n,
      usdB: isA ? 0n : buy.usdIn,
      tokensA: isA ? buy.tokensToBuyer : 0n,
      tokensB: isA ? 0n : buy.tokensToBuyer,
      usdClaimed: 0n,
    });
    await db.update(rounds, { id: buy.roundId }).set((r) => ({ bettors: r.bettors + 1 }));
  }

  await ensurePlayer(db, player);
  await db.update(playerStats, { address: player }).set((p) => ({
    roundsPlayed: existing ? p.roundsPlayed : p.roundsPlayed + 1,
    bets: p.bets + 1,
    usdWagered: p.usdWagered + buy.usdIn,
    lastBetAt: timestamp,
  }));
}
