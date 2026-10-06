# @beeef/indexer

Ponder 0.17 indexer for beeef. Addresses come from `deployments/local.json` (override with `BEEEF_DEPLOYMENT`).

```sh
pnpm fork          # terminal 1: anvil fork of Robinhood Chain with beeef deployed (needs ROBINHOOD_RPC_URL)
pnpm fork:smoke    # a series, a one-off and three bets
cd apps/indexer
DATABASE_URL=postgresql://beeef:beeef@127.0.0.1:5432/beeef pnpm start   # or `pnpm dev` (PGlite, hot reload)
```

`pnpm start` writes to schema `beeef_indexer` and publishes views in `beeef`, which `packages/db` builds on. Apply
the `packages/db` migrations after the first start. GraphQL is served at `/graphql`, Ponder's SQL client at `/sql`.

## Sources
| Source | Events |
| --- | --- |
| BeeefRegistry | `StockSet` |
| BeeefRoundFactory | pairs, series, `RoundCreated`, `RematchStarted`, seed top-ups, stops |
| BeeefClockHook | `ClockBuy` (every seed and bet, with the multiplier) |
| BeeefOracle (factory: `RoundCreated.oracle`) | start/end snapshots, `StartCarriedOver`, `Resolved` |
| Entry tokens (factory: `RoundCreated.entryA/entryB`) | `Transfer`: positions and bet attribution |
| PredictionMigrator | `EntryMigrated` (settled), `Claimed` (only oracles beeef created) |
| BeeefFeeSplitter (factory: `SeriesCreated.feeSplitter`) | `Distributed` |

## Notes
- The bettor is the recipient of the PoolManager -> player `Transfer` of the entry token in the same transaction
  (matched on the exact token amount), never `tx.from`: 4337 bundlers submit players' bets.
- Seed buys (`ClockBuy.sender` = factory) land before `RoundCreated` in the same transaction, so `entries` rows are
  created on the first buy and `RoundCreated` totals them. A rematch starter's seed is re-labelled as their bet.
- A player wins a round when more of their dollars were on the winning side. `usd_won` counts claims by players who
  bet in the round only (series creators redeeming seed are excluded).
