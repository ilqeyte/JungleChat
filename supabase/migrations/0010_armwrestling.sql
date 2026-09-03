-- ============================================================================
-- JUNGLECHAT — 0010_armwrestling.sql  (APPLIED TO PRODUCTION VIA MCP)
--
-- "Beat the animals with thumb: Arm-wrestling"
-- Server-authoritative mini game. Clients never decide outcomes.
--
-- Rules:
--   * Both players tap READY -> 5s countdown -> 60s match window.
--   * First to build a +25 tap lead PINS (wins). At 60s: higher taps wins,
--     equal taps = draw (+1 point each).
--   * Points: win +3, draw +1, loss 0. Awarded exactly once, server-side.
--   * Anti-cheat: taps capped at 20/s by server-measured elapsed time; the
--     live window is server-timestamped; bot strength is rolled server-side.
--
-- NOTE: this migration was applied directly to the production database via
-- the Supabase MCP during development. It is checked in verbatim so the repo
-- mirrors the live schema.
-- ============================================================================

create table if not exists public.armwrestling_matches (
  id              uuid primary key default gen_random_uuid(),
  mode            text not null check (mode in ('bot','pvp')),
  player_a        uuid not null references auth.users(id) on delete cascade,
  player_b        uuid references auth.users(id) on delete cascade,
  invited         uuid references auth.users(id) on delete cascade,
  is_bot          boolean not null default false,
  bot_rate_x100   int,
  status          text not null default 'waiting'
                  check (status in ('waiting','active','finished','cancelled')),
  ready_a         boolean not null default false,
  ready_b         boolean not null default false,
  countdown_start timestamptz,
  taps_a          int not null default 0,
  taps_b          int not null default 0,
  final_a         boolean not null default false,
  final_b         boolean not null default false,
  winner          uuid references auth.users(id) on delete set null,
  is_draw         boolean not null default false,
  points_awarded  boolean not null default false,
  created_at      timestamptz not null default now(),
  ended_at        timestamptz,
  constraint aw_bot_shape_chk check (
    mode <> 'bot' or (is_bot and bot_rate_x100 between 350 and 900 and player_b is null)
  ),
  constraint aw_countdown_chk check (countdown_start is null or status = 'active')
);

create index if not exists aw_waiting_idx on public.armwrestling_matches (created_at)
  where status = 'waiting' and mode = 'pvp' and player_b is null and invited is null;
create index if not exists aw_player_idx on public.armwrestling_matches (player_a, created_at desc);
create index if not exists aw_player_b_idx on public.armwrestling_matches (player_b, created_at desc);
create index if not exists aw_invited_idx on public.armwrestling_matches (invited)
  where invited is not null and status = 'waiting';

create table if not exists public.armwrestling_stats (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  points     int not null default 0,
  wins       int not null default 0,
  losses     int not null default 0,
  draws      int not null default 0,
  best_lead  int not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.armwrestling_matches enable row level security;
alter table public.armwrestling_matches force row level security;
alter table public.armwrestling_stats   enable row level security;
alter table public.armwrestling_stats   force row level security;

revoke all on public.armwrestling_matches from anon, authenticated;
revoke all on public.armwrestling_stats   from anon, authenticated;

create policy aw_matches_select_participant
  on public.armwrestling_matches for select
  to authenticated
  using (player_a = auth.uid() or player_b = auth.uid() or invited = auth.uid());
