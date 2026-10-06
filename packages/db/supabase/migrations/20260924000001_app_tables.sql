-- App-owned tables. Indexer-owned tables (rounds, buys, claims, ...) come from Ponder in the `beeef` schema.
create schema if not exists app;

create table app.users (
  address       text primary key check (address ~ '^0x[0-9a-f]{40}$'),
  privy_id      text unique,
  x_handle      text unique,
  x_avatar      text,
  country_code  char(2),
  -- Players confirm they are not US persons at signup; betting and claiming are blocked without it.
  attested_non_us_at timestamptz,
  sanctions_checked_at timestamptz,
  referrer      text references app.users(address),
  default_payout text not null default 'stock' check (default_payout in ('stock', 'usd')),
  created_at    timestamptz not null default now()
);

-- Display metadata for allowlisted stocks. The allowlist itself (token + feed) is on-chain in the factory.
create table app.stock_meta (
  token_address text primary key check (token_address ~ '^0x[0-9a-f]{40}$'),
  symbol        text not null unique,
  name          text not null,
  sector        text not null,
  logo_url      text,
  feed_address  text not null,
  feed_heartbeat_s   integer not null default 86400,
  feed_deviation_bps integer not null default 50
);

create table app.seasons (
  id         serial primary key,
  name       text not null,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  check (ends_at > starts_at)
);

create table app.badges (
  id    serial primary key,
  slug  text not null unique,
  name  text not null,
  rule  text not null
);

create table app.user_badges (
  address   text not null references app.users(address),
  badge_id  integer not null references app.badges(id),
  earned_at timestamptz not null default now(),
  round_id  text,
  primary key (address, badge_id, round_id)
);

create table app.notifications (
  id       bigserial primary key,
  address  text not null references app.users(address),
  kind     text not null check (kind in ('won', 'claim_ready', 'rival_live', 'seed_low', 'main_event')),
  round_id text,
  series_id text,
  channel  text not null check (channel in ('push', 'telegram', 'x_dm')),
  sent_at  timestamptz not null default now()
);
create index notifications_address_idx on app.notifications (address, sent_at desc);

-- Admin curation: pinned Main Event override and featured rivalries.
create table app.featured (
  id         serial primary key,
  kind       text not null check (kind in ('main_event', 'rivalry')),
  -- numeric(78,0) matches the indexer's uint256 ids.
  pair_id    numeric(78, 0),
  round_id   numeric(78, 0),
  pinned_until timestamptz,
  created_at timestamptz not null default now()
);

insert into app.badges (slug, name, rule) values
  ('early-bird', 'Early bird', 'Won a round with a bet placed at 0.90x or better'),
  ('streak-3', 'Hat trick', '3 wins in a row'),
  ('streak-5', 'On fire', '5 wins in a row'),
  ('streak-10', 'Unstoppable', '10 wins in a row'),
  ('creator', 'Creator', 'Created a matchup that drew at least one outside bet');
