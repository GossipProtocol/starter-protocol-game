// Sanity checks on the migration files (a real Postgres run happens in the local-fork stack).
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

const dir = new URL("../supabase/migrations/", import.meta.url);
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();

test("migrations are ordered and non-empty", () => {
  assert.ok(files.length >= 2);
  for (const f of files) assert.match(f, /^\d{14}_[a-z_]+\.sql$/);
});

test("app migrations never create indexer-owned tables", () => {
  const indexerOwned = ["rounds", "buys", "claims", "series", "pairs", "fee_recipients", "fee_distributions", "player_stats"];
  for (const f of files) {
    const sql = readFileSync(new URL(f, dir), "utf8").toLowerCase();
    for (const t of indexerOwned) assert.ok(!sql.includes(`create table ${t}`) && !sql.includes(`create table app.${t}`), `${f} creates ${t}`);
  }
});

// Applies every migration inside a rolled-back transaction against a database the indexer has already populated
// (`ponder start --views-schema beeef`), then reads each app view. Runs when BEEEF_PG_URL is set and psql exists.
test("migrations apply on top of the indexer views", { skip: !process.env.BEEEF_PG_URL }, async () => {
  const { execFileSync } = await import("node:child_process");
  const sql = [
    "begin;",
    "drop schema if exists app cascade;",
    ...files.map((f) => readFileSync(new URL(f, dir), "utf8")),
    "select count(*) from app.leaderboard_all_time;",
    "select count(*) from app.live_rounds;",
    "select * from app.main_event;",
    "rollback;",
  ].join("\n");
  execFileSync("psql", [process.env.BEEEF_PG_URL, "-v", "ON_ERROR_STOP=1", "-q", "-X"], { input: sql, stdio: ["pipe", "ignore", "pipe"] });
});
