import { index, onchainTable, primaryKey, relations } from "ponder";

// Display read models for beeef. Balances and claimables shown at the moment a player acts are read from the
// contracts; these tables feed lists, round pages, profiles and leaderboards. All USD amounts are USDG base units
// (6 decimals). Moves are WAD ratios (1e18 = unchanged) as BeeefOracle stores them.

export const stocks = onchainTable("stocks", (t) => ({
  address: t.hex().primaryKey(),
  feed: t.hex().notNull(),
  symbol: t.text().notNull(),
}));

export const pairs = onchainTable("pairs", (t) => ({
  id: t.bigint().primaryKey(),
  stockA: t.hex().notNull(),
  stockB: t.hex().notNull(),
  active: t.boolean().notNull(),
  createdAt: t.bigint().notNull(),
}));

export const series = onchainTable(
  "series",
  (t) => ({
    id: t.bigint().primaryKey(),
    pairId: t.bigint().notNull(),
    creator: t.hex().notNull(),
    duration: t.bigint().notNull(),
    recurring: t.boolean().notNull(),
    roundsTotal: t.integer().notNull(),
    endTime: t.bigint().notNull(),
    seedPerRound: t.bigint().notNull(),
    seedBalance: t.bigint().notNull(),
    feeSplitter: t.hex().notNull(),
    /** "active", "stopped", "exhausted", or "closed" (no further rounds: a one-off or rematch once started). */
    status: t.text().notNull(),
    roundsPlayed: t.integer().notNull(),
    lastRoundId: t.bigint(),
    refund: t.bigint(),
    /** Set when this series is the rematch of a finished one-off. */
    rematchOf: t.bigint(),
    createdAt: t.bigint().notNull(),
  }),
  (t) => ({ pairIdx: index().on(t.pairId), creatorIdx: index().on(t.creator) }),
);

export const rounds = onchainTable(
  "rounds",
  (t) => ({
    id: t.bigint().primaryKey(),
    seriesId: t.bigint().notNull(),
    pairId: t.bigint().notNull(),
    roundNumber: t.integer().notNull(),
    prevRoundId: t.bigint(),
    oracle: t.hex().notNull(),
    entryA: t.hex().notNull(),
    entryB: t.hex().notNull(),
    startTime: t.bigint().notNull(),
    endTime: t.bigint().notNull(),
    lockTime: t.bigint().notNull(),
    floorWad: t.bigint().notNull(),
    carriedStart: t.boolean().notNull(),
    startPriceA: t.bigint(),
    startPriceB: t.bigint(),
    endPriceA: t.bigint(),
    endPriceB: t.bigint(),
    moveA: t.bigint(),
    moveB: t.bigint(),
    /** Oracle outcome: 0 pending, 1 A, 2 B, 3 void tie, 4 void start missed, 5 void end missed. */
    outcome: t.integer().notNull(),
    /** "A" | "B" | "VOID", null until resolved. */
    winner: t.text(),
    potA: t.bigint().notNull(),
    potB: t.bigint().notNull(),
    totalPotUsd: t.bigint().notNull(),
    seedUsd: t.bigint().notNull(),
    bets: t.integer().notNull(),
    bettors: t.integer().notNull(),
    settled: t.boolean().notNull(),
    rematchRoundId: t.bigint(),
    createdAt: t.bigint().notNull(),
    resolvedAt: t.bigint(),
  }),
  (t) => ({
    seriesIdx: index().on(t.seriesId),
    pairIdx: index().on(t.pairId),
    oracleIdx: index().on(t.oracle),
    winnerIdx: index().on(t.winner),
  }),
);

/** One per entry token. Created by the first seed buy, which lands before RoundCreated in the same transaction. */
export const entries = onchainTable("entries", (t) => ({
  address: t.hex().primaryKey(),
  roundId: t.bigint(),
  /** "A" | "B", null until RoundCreated. */
  side: t.text(),
  usdIn: t.bigint().notNull(),
  tokensSold: t.bigint().notNull(),
  tokensWithheld: t.bigint().notNull(),
  seedBuyId: t.text(),
  contribution: t.bigint(),
  claimableSupply: t.bigint(),
}));

export const buys = onchainTable(
  "buys",
  (t) => ({
    id: t.text().primaryKey(),
    entry: t.hex().notNull(),
    roundId: t.bigint(),
    side: t.text(),
    /** Token recipient, from the PoolManager -> player Transfer in the same tx (4337 makes tx.from useless). */
    buyer: t.hex(),
    isSeed: t.boolean().notNull(),
    usdIn: t.bigint().notNull(),
    tokensToBuyer: t.bigint().notNull(),
    tokensWithheld: t.bigint().notNull(),
    multiplierWad: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (t) => ({ roundIdx: index().on(t.roundId), buyerIdx: index().on(t.buyer) }),
);

/** A player's bets in one round, the unit for wins, losses and streaks. */
export const roundPlayers = onchainTable(
  "round_players",
  (t) => ({
    roundId: t.bigint().notNull(),
    player: t.hex().notNull(),
    usdA: t.bigint().notNull(),
    usdB: t.bigint().notNull(),
    tokensA: t.bigint().notNull(),
    tokensB: t.bigint().notNull(),
    /** "win" | "loss" | "void", null until resolved. */
    result: t.text(),
    usdClaimed: t.bigint().notNull(),
  }),
  (t) => ({ pk: primaryKey({ columns: [t.roundId, t.player] }), playerIdx: index().on(t.player) }),
);

/** Entry token balances, from every Transfer. */
export const positions = onchainTable(
  "positions",
  (t) => ({
    entry: t.hex().notNull(),
    holder: t.hex().notNull(),
    balance: t.bigint().notNull(),
  }),
  (t) => ({ pk: primaryKey({ columns: [t.entry, t.holder] }), holderIdx: index().on(t.holder) }),
);

export const claims = onchainTable(
  "claims",
  (t) => ({
    id: t.text().primaryKey(),
    roundId: t.bigint().notNull(),
    claimer: t.hex().notNull(),
    tokensBurned: t.bigint().notNull(),
    usdReceived: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (t) => ({ roundIdx: index().on(t.roundId), claimerIdx: index().on(t.claimer) }),
);

export const playerStats = onchainTable("player_stats", (t) => ({
  address: t.hex().primaryKey(),
  roundsPlayed: t.integer().notNull(),
  bets: t.integer().notNull(),
  wins: t.integer().notNull(),
  losses: t.integer().notNull(),
  voids: t.integer().notNull(),
  usdWagered: t.bigint().notNull(),
  usdWon: t.bigint().notNull(),
  currentStreak: t.integer().notNull(),
  bestStreak: t.integer().notNull(),
  lastBetAt: t.bigint(),
}));

export const feeRecipients = onchainTable(
  "fee_recipients",
  (t) => ({
    feeSplitter: t.hex().notNull(),
    recipient: t.hex().notNull(),
    bps: t.integer().notNull(),
  }),
  (t) => ({ pk: primaryKey({ columns: [t.feeSplitter, t.recipient] }) }),
);

export const feeDistributions = onchainTable(
  "fee_distributions",
  (t) => ({
    id: t.text().primaryKey(),
    feeSplitter: t.hex().notNull(),
    token: t.hex().notNull(),
    recipient: t.hex().notNull(),
    amount: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (t) => ({ splitterIdx: index().on(t.feeSplitter), recipientIdx: index().on(t.recipient) }),
);

// Lookup tables for handlers.

export const oracles = onchainTable("oracles", (t) => ({
  address: t.hex().primaryKey(),
  roundId: t.bigint().notNull(),
}));

/** A bet waiting for its PoolManager -> player Transfer, keyed by `${txHash}-${entry}-${tokensToBuyer}`. */
export const pendingBuys = onchainTable("pending_buys", (t) => ({
  id: t.text().primaryKey(),
  buyId: t.text().notNull(),
}));

export const roundsRelations = relations(rounds, ({ one, many }) => ({
  pair: one(pairs, { fields: [rounds.pairId], references: [pairs.id] }),
  series: one(series, { fields: [rounds.seriesId], references: [series.id] }),
  buys: many(buys),
}));

export const buysRelations = relations(buys, ({ one }) => ({
  round: one(rounds, { fields: [buys.roundId], references: [rounds.id] }),
}));
