# starter-protocol-game

Head-to-head tokenized stock battles on Robinhood Chain, built on Doppler's prediction market stack plus a custom time-decay hook. Stock A versus stock B over a fixed round, the higher percentage move wins, and the losing side's dollars go to the winners pro rata. Creators run one-off rounds or recurring series, players buy a side with USDG at any point in the round, and the earlier they buy the more of the pot their dollars own. This is Module 8 starter from the course, cut down from a product that ran full rounds end to end on a local fork of Robinhood Chain.

It runs in two modes:

- **Demo mode** (no RPC, no database): `forge test` deploys a fresh Doppler stack in memory, runs whole rounds against mock feeds and stock tokens, and checks the SDK against vectors the contracts wrote. Nothing outside your machine is touched.
- **Live mode**: an anvil fork of Robinhood Chain with the real Airlock, PoolManager, USDG, stock tokens and Chainlink feeds, the contracts deployed on top, a Ponder indexer feeding Postgres, and Supabase migrations over the indexer's views. The same scripts deploy to the chain itself once the course fee recipient is set.

## The fee, stated plainly

Every series pays **1% of its collected integrator fees** to the course wallet. Each series has its own `BeeefFeeSplitter`, which is the Airlock integrator for every round in the series, so the integrator share of each round pool's LP fees lands in that splitter at migration. When the splitter distributes, it pays the course fee first, then the platform cut, then the creator's recipients by their bps. The fee never comes out of the pot: players who win are paid the whole losing side, exactly as before. The rate and the recipient live in one file, `packages/contracts/src/CourseFee.sol`, and `BeeefRegistry` reports them through `courseFee()` and counts the course bps toward its 20% ceiling on platform plus course fees.

The deploy script refuses to run on any chain other than a local anvil fork if the recipient is the zero address, so the fee cannot be dropped on the way to production.

The fee is a default, not a license condition. This code is MIT licensed, so you can change it. If you change the recipient or the rate, say so in your README.

## What is in the box

| Area | Where | What it teaches |
|------|-------|-----------------|
| The round oracle | `packages/contracts/src/BeeefOracle.sol` | One EIP-1167 clone per round, because the PredictionMigrator keys a market by its oracle. Chainlink snapshots, exact ratio comparison, void on tie or bad data. |
| Rounds and series | `packages/contracts/src/BeeefRoundFactory.sol` | Pairs, one-offs, recurring series, rollover with the previous end price, rematches started by a player's bet, settlement through the migrator. |
| Staying under EIP-170 | `packages/contracts/src/BeeefRegistry.sol`, `src/libraries/` | The factory sits near the 24,576 byte limit. Admin config moved to the registry and the Airlock parameter builder became a linked library. `forge build --sizes` is part of the workflow. |
| Time-decay hook | `packages/contracts/src/BeeefClockHook.sol` | A Doppler hook that blocks sells, locks buys before the bell, rejects exact-output buys and withholds a share of the tokens that falls from 0% to 90% over the round. The withheld tokens go to the migrator and burn as unsold. |
| Fee routing | `packages/contracts/src/BeeefFeeSplitter.sol`, `src/CourseFee.sol` | One splitter clone per series as the Airlock integrator. Course fee, platform cut, then creator recipients. |
| Market calendar | `packages/contracts/src/libraries/BeeefCalendar.sol`, `packages/sdk/src/calendar.ts` | Weekly close and holidays for 24/5 equity feeds, with the same maths on both sides. |
| SDK parity | `packages/sdk/`, `packages/contracts/test/vectors/SdkVectors.t.sol` | The contracts write `packages/sdk/test/vectors.json`; the TypeScript multiplier, lock time, move and payout maths must match it exactly. |
| Indexer | `apps/indexer/` | Ponder 0.17 over the factory, hook, oracles, entry tokens, migrator and splitters. Bettors come from the entry token transfer, never `tx.from`, because account abstraction bundlers submit bets. |
| App tables | `packages/db/` | Supabase migrations over the indexer's views: users, seasons, badges, featured rounds. |
| Local stack | `scripts/local-fork.sh`, `packages/contracts/script/` | Anvil fork, deploy, module registration by impersonating the Airlock owner, USDG for dev wallets, then a smoke script that creates a series, a one-off and three bets. |
| Design spec | `docs/design/` | `CLAYMORPHISM.md` is the claymorphism design spec written for AI agents (tokens, shadow recipes, copy rules, accessibility floors) and `battle.html` is the static round page prototype in its live, locked and closed states. Module 9 builds the capstone page from these, including the spec's one deliberate contradiction. |

## Run it in demo mode

```bash
git submodule update --init --recursive   # pulls Doppler at the pinned commit (BUSL-1.1, never copied into src/)
pnpm install
cd packages/contracts && forge build && forge test
cd ../.. && pnpm typecheck && pnpm test
```

`forge test` runs the unit suites, the full local round (`BeeefRoundLocal.t.sol`) and writes the SDK vectors. The fork suite skips itself until `ROBINHOOD_RPC_URL` is set.

Install the Doppler skills before writing any Doppler code:

```bash
npx skills add whetstoneresearch/doppler-skills -a claude-code
```

## Go live on a fork, then on the chain

1. **RPC.** Copy `packages/contracts/.env.example` to `packages/contracts/.env` and set `ROBINHOOD_RPC_URL`. `forge test` now also runs `BeeefRoundFork.t.sol` against the live Airlock, PoolManager, USDG, NVDA and AMD.
2. **Fork.** `pnpm fork` starts anvil on chain id 31337, deploys the contracts, registers the migrator and the hook on the Airlock by impersonating its owner, and gives the five anvil dev wallets 10,000 USDG each. `pnpm fork:smoke` creates a recurring NVDA vs AMD series, a one-off TSLA vs AAPL and three bets.
3. **Indexer.** In `apps/indexer`, `pnpm dev` runs on PGlite with hot reload, or `DATABASE_URL=... pnpm start` writes to Postgres and publishes views in the `beeef` schema. Then apply the `packages/db` migrations.
4. **Fee wallet.** `packages/contracts/src/CourseFee.sol` already carries the course fee rate and recipient. Leave them as they are.
5. **Chain.** On Robinhood Chain the factory needs a PredictionMigrator and a BeeefClockHook that the Airlock owner has registered. Write a `Deploy.s.sol` modelled on `DeployLocal.s.sol`, point `migrator` at the published one, set `applyMultiplier = false` because Robinhood feeds already include `uiMultiplier()`, and write `deployments/4663.json` for the indexer.

Copy `.env.example` to `.env` and fill the groups as you go. Each group switches on independently.

## How a live round works

```
creator                       factory                                   Doppler / chain
  createSeries(A, B, 1h) ->   pair found or created
                              oracle clone + init (feeds, window)
                              fee splitter clone + init (course, platform, creator)
                              Airlock.create(entry A) + create(entry B) ---> two pools, PredictionMigrator
                              seed buy on each side via PoolManager unlock
                              RoundCreated, then presetStart / snapshotStart
player
  buy side A with USDG ->     BeeefClockHook.onSwap: sell? revert
                                                     after lockTime? revert
                                                     exact output? revert
                                                     withhold tokensOut * (1 - m(t)) -> migrator
  <- entry tokens * m(t)
keeper
  rollover(seriesId) ->       oracle snapshotEnd, Resolved(winner | void)
                              next round starts at prev end with prev end price
  settle(roundId) ->          Airlock.migrate(entry A), migrate(entry B)
                              migrator burns withheld tokens as unsold
player
  claim ->                    PredictionMigrator pays winners pro rata from both pools
splitter
  collectAndDistribute ->     course fee, platform cut, creator recipients
```

Five things are enforced here that are the reason this starter exists:

- **One oracle per round.** The migrator keys a market by its oracle, so every round gets its own clone, and the clone's `startTime` is pinned before its first snapshot. The indexer relies on `RoundCreated` landing before any oracle event in the same transaction.
- **The factory stays under the limit.** Config lives in the registry, the Airlock `CreateParams` builder is a linked library, and the factory compiles with `optimizer_runs = 1`. Every factory change is followed by `forge build --sizes`.
- **The hook never holds a token.** Withheld tokens cannot be burned mid-round because DopplerERC20V1 rejects transfers to its locked pool, so the hook takes them straight to the migrator, which burns them as unsold at migration.
- **The SDK matches the contracts exactly.** Vectors are written by the contracts in a forge test and the TypeScript tests fail on any drift.
- **Bets are attributed by token transfer.** `tx.from` is a bundler for players on smart accounts, so the indexer finds the bettor from the entry token `Transfer` out of the PoolManager in the same transaction.

## What is left for you

The contracts, SDK, indexer and local stack are complete and verified on a fork. There is no web app, no keeper and no price service yet. The first milestone of the module is a keeper (`apps/keeper`) that watches running rounds and calls `rollover` and `settle` at the right time, with a test that drives a whole series through on the fork. The capstone is a playable battle page on the fork: a pair picker, the live multiplier dial, a bet form through a router, claims after settlement, and a leaderboard read from the indexer's views.

## Legal note

A head-to-head stake on price moves with a pooled payout is a prediction market or a game of chance in many jurisdictions, and the underlying assets are tokenized equities. Gate by geography, publish the rules and the multiplier curve, and talk to counsel before anything other than a local fork. The course covers this in Module 8.

## Course

Consumer Layer, the course this starter is taught in, covers it in Module 8, with the Doppler skills installed from Module 0 onward. The course plugin's `protocol-game` skill coaches each milestone and the `review` skill checks your fork against the module checklist.
