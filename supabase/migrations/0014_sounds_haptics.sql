-- ============================================================================
-- JUNGLECHAT - 0014_sounds_haptics.sql  (APPLIED TO PRODUCTION VIA MCP)
-- Sound & haptic preferences + typing state + push infrastructure columns.
-- ============================================================================
alter table public.profiles
  add column if not exists sounds_enabled boolean not null default true,
  add column if not exists haptics_enabled boolean not null default true;
alter table public.conversations
  add column if not exists typing_a_until timestamptz,
  add column if not exists typing_b_until timestamptz,
  add column if not exists last_read_a timestamptz,
  add column if not exists last_read_b timestamptz;
alter table public.notifications
  add column if not exists pushed_at timestamptz;