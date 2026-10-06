# @beeef/db

Two kinds of tables live in the same Supabase Postgres:

| Owner | Tables | Source of truth | How it changes |
| --- | --- | --- | --- |
| Indexer (Ponder, `apps/indexer/ponder.schema.ts`) | `pairs`, `series`, `rounds`, `buys`, `claims`, `fee_recipients`, `fee_distributions`, `player_stats` | Chain events | Ponder rebuilds them from scratch on any schema change. Never write to them by hand. Published as views in the `beeef` schema (`ponder start --views-schema beeef`). |
| App (this package, `supabase/migrations`) | `users`, `stock_meta`, `seasons`, `badges`, `user_badges`, `notifications`, `featured` | The app | Supabase migrations (`supabase db push`). |

Views in `app` join the two (leaderboards, profiles). The web app reads balances and claimables from the contracts at
the moment the player acts; these tables are only for display.
