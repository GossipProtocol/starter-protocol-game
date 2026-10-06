-- Read models joining indexer views (schema `beeef`, published by `ponder start --views-schema beeef`) with app tables.
-- Created as views so they stay correct across indexer rebuilds.

create or replace view app.leaderboard_all_time as
select
  s.address,
  u.x_handle,
  u.x_avatar,
  s.rounds_played,
  s.wins,
  s.losses,
  s.voids,
  s.usd_won,
  s.usd_wagered,
  s.current_streak,
  s.best_streak,
  case when s.rounds_played >= 10 then round(s.wins::numeric / nullif(s.wins + s.losses, 0), 4) end as win_rate
from beeef.player_stats s
left join app.users u on u.address = s.address;

-- Symbols come from the on-chain registry (beeef.stocks); stock_meta adds display names and logos.
create or replace view app.live_rounds as
select
  r.*,
  sa.symbol as symbol_a,
  sb.symbol as symbol_b,
  ma.name as name_a,
  mb.name as name_b,
  ma.logo_url as logo_a,
  mb.logo_url as logo_b
from beeef.rounds r
join beeef.pairs p on p.id = r.pair_id
left join beeef.stocks sa on sa.address = p.stock_a
left join beeef.stocks sb on sb.address = p.stock_b
left join app.stock_meta ma on ma.token_address = p.stock_a
left join app.stock_meta mb on mb.token_address = p.stock_b
where r.winner is null;

-- Main Event: the live round with the biggest pot, unless an admin pinned one.
create or replace view app.main_event as
select coalesce(
  (select f.round_id from app.featured f
     where f.kind = 'main_event' and (f.pinned_until is null or f.pinned_until > now())
     order by f.created_at desc limit 1),
  (select r.id from beeef.rounds r where r.winner is null order by r.total_pot_usd desc limit 1)
) as round_id;
