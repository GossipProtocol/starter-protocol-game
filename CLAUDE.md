# starter-protocol-game

Head-to-head tokenized stock battles on Robinhood Chain (4663), built on Doppler's prediction market stack
(`PredictionMigrator` from the pinned `lib/doppler` submodule) plus our own `BeeefClockHook`. Stock A vs stock B, the
higher % move wins, losers' USD goes 100% to winners pro rata. Read `README.md` for the map and the fee before
changing anything under `packages/contracts/src`.

The Doppler skills are installed before any Doppler code is written: `npx skills add whetstoneresearch/doppler-skills -a claude-code`.

Creators make a one-off (a single round) or a recurring series (rounds back to back until N rounds, an end date, or
a manual stop; several series can run on one pair). Within a series the next round starts at the previous end with
the previous end price; the first round of any series takes a fresh price. Bets are open the whole round and lock
`min(60s, 10% of the round)` before the end. A share multiplier falls linearly from 1.00x at the start to 0.10x at the
lock, so early bets own more of the pot. There is no halfway cutoff and no "bets close at start" mode.

## Layout (pnpm monorepo)
Contracts live in `packages/contracts` (paths below are relative to it).
- `packages/config`: chain 4663 definition, public Robinhood and Doppler addresses, stock allowlist seed, env schema.
- `packages/sdk`: generated ABIs, round state machine, multiplier / lock time / % move / payout / quote maths and the
  market calendar. `test/vectors.json` is written by `test/vectors/SdkVectors.t.sol` from the real contracts and the
  sdk tests must match it exactly. Regenerate after any contract maths change: `forge test --match-contract SdkVectors`.
- `packages/db`: Postgres (Supabase) migrations over the indexer's `beeef.*` views.
- `apps/indexer`: Ponder 0.17 (see its README). Bettors come from the entry-token Transfer out of the PoolManager,
  never `tx.from`. Seeds and the fresh start snapshot happen before `RoundCreated` in the same tx; keep
  `RoundCreated` emitted before `presetStart`/`snapshotStart` so the oracle is known before its first event. Still to
  build: `apps/web`, `apps/keeper`, `apps/price-service`, `packages/ui`.
- `src/BeeefOracle.sol`: per-round EIP-1167 clone implementing `IPredictionOracle`, Chainlink snapshots, void rules.
- `src/BeeefRoundFactory.sol`: pairs (auto-created, order independent), series and rounds. `createOneOff`,
  `createSeries`, `rollover(seriesId)` (finalizes the ended round, starts the next or closes an exhausted series),
  `stopSeries` (refunds unused seed), `topUpSeed`, `rematch(roundId, side, amount)` (a player's bet starts the
  rematch of a finished one-off; never automatic; one per round), `settle(roundId)` (migrates both entries).
- `src/BeeefRegistry.sol`: admin config the factory reads (stock allowlist and feeds, durations, market calendar, pool
  config, oracle/clock settings, min seed, platform fee, course fee). Split out to keep the factory under EIP-170.
- `src/CourseFee.sol`: the course fee rate and recipient. One file, the default the course relies on.
- `src/libraries/`: `BeeefCalendar` (weekly close + holidays), `BeeefEntryData` (linked: Airlock CreateParams builder,
  oracle clone + init). Linked library functions are how the factory stays small.
- `src/BeeefFeeSplitter.sol`: one clone per series; the Airlock integrator for its rounds. Course fee, platform cut,
  then the creator's recipients by bps.
- `src/BeeefClockHook.sol`: Doppler hook for round pools. Blocks sells, blocks buys from `lockTime`, rejects
  exact-output buys, and withholds `tokensOut * (1 - m(t))` by taking it to the PredictionMigrator.
- `src/interfaces/`: MIT redeclarations of the Doppler, Chainlink and Robinhood ABI calls this code makes.
- `test/unit`, `test/integration`: local Doppler deployment and Robinhood Chain fork (`BeeefRoundFork.t.sol`).
- `lib/doppler`: git submodule pinned to the commit in `.gitmodules` (nested submodules provide forge-std, solady, v4).

## Settled decisions. Do not relitigate these.

- One oracle clone per round, because the PredictionMigrator keys a market by its oracle address.
- The registry holds config and the factory holds flow. Anything that does not need to be in the factory is not.
- The multiplier is charged in entry tokens, never in USD, so the pot is always the full sum of stakes.
- The course fee in `src/CourseFee.sol` stays in place.

## Rules
- Doppler is BUSL-1.1. Never import or copy Doppler source into `src/`, because the license does not allow
  redistribution in this repo. Tests and scripts may import it via `doppler/...` from the submodule.
- Never set `applyMultiplier = true` for Robinhood Chainlink feeds, because their answers already include
  `uiMultiplier()` and the move would be scaled twice.
- Never use `bytes32(0)` as an entry id, because the PredictionMigrator treats it as "unregistered".
- Never put beneficiaries in the pool config or move `farTick` away from `startingTick`, and never set a zero fee,
  because the integrator share is where every fee in this system comes from.
- Never steepen the curve (see `_defaultPoolConfig`), because a steep curve adds a second early-bettor bonus on top
  of the clock multiplier (a $10 bet at the start paid 6.2x a late one instead of 5.3x on the old 1M-token curve).
- Never burn entry tokens mid-round, because DopplerERC20V1 on 4663 reverts transfers to its locked pool (address(0)
  for prediction markets). Withheld tokens go to the migrator, which burns them as unsold at migrate.
- Never pool or withdraw series seed in the factory, because each series' `seedBalance` is its own. Unused seed is
  refunded to the series creator on stop or exhaustion.
- Never unblock exact-output buys in the hook, because their hook fee would come out of the USD side, i.e. the pot.
- Never let BeeefRoundFactory pass 24,576 bytes, because it will not deploy. Runtime is ~23.9KB (compiled with
  `optimizer_runs = 1` via `compilation_restrictions`). Check `forge build --sizes` after any factory change; move
  logic into the registry or a linked library. (`--sizes` also flags Doppler's DopplerHookInitializer, which is only
  deployed in tests.)
- Never attribute a bet to `tx.from` in the indexer, because account abstraction bundlers submit players' bets.
- Never lower the course fee or change its recipient unless the user explicitly asks for that change by name, because the
  fee is the course's revenue and the README states it openly. The deploy script refuses a non-local deployment while the recipient is unset.
- Never commit `deployments/*.json`, broadcast output or `.env` files.

## Commands
- `git submodule update --init --recursive`, `pnpm install`
- In `packages/contracts`: `forge build`, `forge test` (fork suite skips unless `ROBINHOOD_RPC_URL` is set, see
  `.env.example`), `forge fmt src test`
- `pnpm abis` re-exports ABIs into `packages/sdk/src/abis` after contract changes.
- `pnpm test`, `pnpm typecheck` for the TypeScript packages.
- Local stack: `pnpm fork` (anvil fork + deploy + Airlock module registration + USDG for dev wallets),
  `pnpm fork:smoke`, then `pnpm start` in `apps/indexer` with `DATABASE_URL` set, then apply `packages/db` migrations.
- `forge test` prints "file src/... not found" lines after compiling: forge's source parser ignores the
  `lib/doppler/:src/=` context remapping. Compilation and results are unaffected.
- Commit messages name the milestone and the proof: the test you ran, the fork transaction, the screenshot.
