import { ponder } from "ponder:registry";
import { claims, entries, feeDistributions, oracles, playerStats, roundPlayers, rounds } from "ponder:schema";

import { ensurePlayer, eventId, lc } from "./lib";

// The PredictionMigrator can serve other integrators' markets; only oracles beeef created are indexed.

ponder.on("PredictionMigrator:EntryMigrated", async ({ event, context }) => {
  const { db } = context;
  const o = await db.find(oracles, { address: lc(event.args.oracle) });
  if (!o) return;
  await db
    .update(entries, { address: lc(event.args.token) })
    .set({ contribution: event.args.contribution, claimableSupply: event.args.claimableSupply });
  const round = await db.find(rounds, { id: o.roundId });
  if (!round) return;
  const a = await db.find(entries, { address: round.entryA });
  const b = await db.find(entries, { address: round.entryB });
  if (a?.contribution != null && b?.contribution != null) await db.update(rounds, { id: o.roundId }).set({ settled: true });
});

ponder.on("PredictionMigrator:Claimed", async ({ event, context }) => {
  const { db } = context;
  const o = await db.find(oracles, { address: lc(event.args.oracle) });
  if (!o) return;
  const claimer = lc(event.args.claimer);
  const received = event.args.numeraireReceived;
  await db.insert(claims).values({
    id: eventId(event),
    roundId: o.roundId,
    claimer,
    tokensBurned: event.args.tokensBurned,
    usdReceived: received,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  });
  // Winnings count for players who bet in the round; a series creator redeeming seed tokens is not a win.
  if (!(await db.find(roundPlayers, { roundId: o.roundId, player: claimer }))) return;
  await db
    .update(roundPlayers, { roundId: o.roundId, player: claimer })
    .set((rp) => ({ usdClaimed: rp.usdClaimed + received }));
  await ensurePlayer(db, claimer);
  await db.update(playerStats, { address: claimer }).set((p) => ({ usdWon: p.usdWon + received }));
});

ponder.on("BeeefFeeSplitter:Distributed", async ({ event, context }) => {
  await context.db.insert(feeDistributions).values({
    id: eventId(event),
    feeSplitter: lc(event.log.address),
    token: lc(event.args.token),
    recipient: lc(event.args.recipient),
    amount: event.args.amount,
    timestamp: event.block.timestamp,
  });
});
