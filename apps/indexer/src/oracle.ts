import { Outcome } from "@beeef/sdk";
import { ponder } from "ponder:registry";
import { oracles, playerStats, roundPlayers, rounds } from "ponder:schema";
import { eq } from "ponder";

import { type Db, lc } from "./lib";

async function roundIdOf(db: Db, oracle: `0x${string}`) {
  return (await db.find(oracles, { address: lc(oracle) }))?.roundId ?? null;
}

ponder.on("BeeefOracle:StartSnapshot", async ({ event, context }) => {
  const id = await roundIdOf(context.db, event.log.address);
  if (id === null) return;
  await context.db.update(rounds, { id }).set({ startPriceA: event.args.priceA, startPriceB: event.args.priceB });
});

/** Series rounds after the first start at the previous round's end price. */
ponder.on("BeeefOracle:StartCarriedOver", async ({ event, context }) => {
  const id = await roundIdOf(context.db, event.log.address);
  if (id === null) return;
  const round = await context.db.find(rounds, { id });
  const prev = round?.prevRoundId != null ? await context.db.find(rounds, { id: round.prevRoundId }) : null;
  if (!prev) return;
  await context.db.update(rounds, { id }).set({ startPriceA: prev.endPriceA, startPriceB: prev.endPriceB });
});

ponder.on("BeeefOracle:EndSnapshot", async ({ event, context }) => {
  const id = await roundIdOf(context.db, event.log.address);
  if (id === null) return;
  await context.db.update(rounds, { id }).set({ endPriceA: event.args.priceA, endPriceB: event.args.priceB });
});

ponder.on("BeeefOracle:Resolved", async ({ event, context }) => {
  const { db } = context;
  const id = await roundIdOf(db, event.log.address);
  if (id === null) return;
  const outcome = event.args.outcome;
  const winner = outcome === Outcome.WinnerA ? "A" : outcome === Outcome.WinnerB ? "B" : "VOID";
  await db.update(rounds, { id }).set({
    outcome,
    winner,
    moveA: event.args.moveA,
    moveB: event.args.moveB,
    resolvedAt: event.block.timestamp,
  });

  // A player wins a round when more of their dollars were on the winning side.
  const players = await db.sql.select().from(roundPlayers).where(eq(roundPlayers.roundId, id));
  for (const rp of players) {
    const onWinner = winner === "A" ? rp.usdA : rp.usdB;
    const onLoser = winner === "A" ? rp.usdB : rp.usdA;
    const result = winner === "VOID" ? "void" : onWinner > onLoser ? "win" : "loss";
    await db.update(roundPlayers, { roundId: id, player: rp.player }).set({ result });
    await db.update(playerStats, { address: rp.player }).set((p) => {
      if (result === "void") return { voids: p.voids + 1 };
      if (result === "loss") return { losses: p.losses + 1, currentStreak: 0 };
      const streak = p.currentStreak + 1;
      return { wins: p.wins + 1, currentStreak: streak, bestStreak: Math.max(streak, p.bestStreak) };
    });
  }
});
