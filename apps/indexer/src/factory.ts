import { NO_ROUND, beeefFeeSplitterAbi, beeefRoundFactoryAbi } from "@beeef/sdk";
import { type Context, ponder } from "ponder:registry";
import { buys, entries, feeRecipients, oracles, pairs, rounds, series } from "ponder:schema";

import { deployment } from "./deployment";
import { lc } from "./lib";
import { recordBet } from "./bets";

ponder.on("BeeefRoundFactory:PairCreated", async ({ event, context }) => {
  await context.db.insert(pairs).values({
    id: event.args.pairId,
    stockA: lc(event.args.stockA),
    stockB: lc(event.args.stockB),
    active: true,
    createdAt: event.block.timestamp,
  });
});

ponder.on("BeeefRoundFactory:PairActiveSet", async ({ event, context }) => {
  await context.db.update(pairs, { id: event.args.pairId }).set({ active: event.args.active });
});

ponder.on("BeeefRoundFactory:SeriesCreated", async ({ event, context }) => {
  const a = event.args;
  await context.db.insert(series).values({
    id: a.seriesId,
    pairId: a.pairId,
    creator: lc(a.creator),
    duration: a.duration,
    recurring: a.recurring,
    roundsTotal: a.roundsTotal,
    endTime: a.endTime,
    seedPerRound: a.seedPerRound,
    seedBalance: 0n,
    feeSplitter: lc(a.feeSplitter),
    status: "active",
    roundsPlayed: 0,
    createdAt: event.block.timestamp,
  });

  // Rematches reuse the original series' splitter; its recipients are already recorded.
  const [recipients, bps] = await context.client.readContract({
    abi: beeefFeeSplitterAbi,
    address: a.feeSplitter,
    functionName: "recipients",
  });
  for (let i = 0; i < recipients.length; i++) {
    await context.db
      .insert(feeRecipients)
      .values({ feeSplitter: lc(a.feeSplitter), recipient: lc(recipients[i]!), bps: bps[i]! })
      .onConflictDoNothing();
  }
  await syncSeries(context, a.seriesId);
});

ponder.on("BeeefRoundFactory:SeedToppedUp", async ({ event, context }) => {
  await context.db.update(series, { id: event.args.seriesId }).set({ seedBalance: event.args.seedBalance });
});

ponder.on("BeeefRoundFactory:SeriesStopped", async ({ event, context }) => {
  await context.db
    .update(series, { id: event.args.seriesId })
    .set({ status: "stopped", refund: event.args.refund, seedBalance: 0n });
});

ponder.on("BeeefRoundFactory:SeriesExhausted", async ({ event, context }) => {
  await context.db
    .update(series, { id: event.args.seriesId })
    .set({ status: "exhausted", refund: event.args.refund, seedBalance: 0n });
});

ponder.on("BeeefRoundFactory:RoundCreated", async ({ event, context }) => {
  const a = event.args;
  const { db } = context;
  // Both entries were seeded earlier in this transaction, so their rows (and seed buys) already exist.
  const entryA = lc(a.entryA);
  const entryB = lc(a.entryB);
  const ea = await db.find(entries, { address: entryA });
  const eb = await db.find(entries, { address: entryB });
  const potA = ea?.usdIn ?? 0n;
  const potB = eb?.usdIn ?? 0n;

  await db.insert(rounds).values({
    id: a.roundId,
    seriesId: a.seriesId,
    pairId: a.pairId,
    roundNumber: a.roundNumber,
    prevRoundId: a.prevRoundId === NO_ROUND ? null : a.prevRoundId,
    oracle: lc(a.oracle),
    entryA,
    entryB,
    startTime: a.startTime,
    endTime: a.endTime,
    lockTime: a.lockTime,
    floorWad: a.floorWad,
    carriedStart: a.carriedStart,
    outcome: 0,
    potA,
    potB,
    totalPotUsd: potA + potB,
    seedUsd: potA + potB,
    bets: 0,
    bettors: 0,
    settled: false,
    createdAt: event.block.timestamp,
  });
  await db.insert(oracles).values({ address: lc(a.oracle), roundId: a.roundId });

  for (const [e, side] of [[ea, "A"], [eb, "B"]] as const) {
    if (!e) continue;
    await db.update(entries, { address: e.address }).set({ roundId: a.roundId, side });
    if (e.seedBuyId) await db.update(buys, { id: e.seedBuyId }).set({ roundId: a.roundId, side });
  }

  await db.update(series, { id: a.seriesId }).set({ lastRoundId: a.roundId, roundsPlayed: a.roundNumber });
  await syncSeries(context, a.seriesId);
});

/** A player's bet started the rematch: their side's seed is a real bet by them. */
ponder.on("BeeefRoundFactory:RematchStarted", async ({ event, context }) => {
  const { prevRoundId, roundId, seriesId, starter, sideA } = event.args;
  const { db } = context;
  await db.update(rounds, { id: prevRoundId }).set({ rematchRoundId: roundId });
  await db.update(series, { id: seriesId }).set({ rematchOf: prevRoundId });

  const round = await db.find(rounds, { id: roundId });
  const entry = round && (await db.find(entries, { address: sideA ? round.entryA : round.entryB }));
  if (!entry?.seedBuyId) return;
  const buy = await db.update(buys, { id: entry.seedBuyId }).set({ isSeed: false });
  await db.update(rounds, { id: roundId }).set((r) => ({ seedUsd: r.seedUsd - buy.usdIn, bets: r.bets + 1 }));
  await recordBet(db, buy.id, lc(starter), event.block.timestamp);
});

/** Seed balance and status as of the end of this block. */
async function syncSeries(context: Context, seriesId: bigint) {
  const s = await context.client.readContract({
    abi: beeefRoundFactoryAbi,
    address: deployment.factory,
    functionName: "getSeries",
    args: [seriesId],
  });
  await context.db.update(series, { id: seriesId }).set((row) => ({
    seedBalance: s.seedBalance,
    roundsPlayed: s.roundsPlayed,
    status: s.active ? "active" : row.status === "active" ? "closed" : row.status,
  }));
}
