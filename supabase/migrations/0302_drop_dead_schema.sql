-- ============================================================================
-- 0302 — Drop dead schema: armwrestling + orphaned room RPCs/cron (item #5).
--
-- - armwrestling_* tables (0010): zero Dart references, unrelated to ads.
-- - room RPCs (0005) + expire_temporary_rooms (0007): the `rooms` table was
--   dropped in 0011, so these functions reference a non-existent table and are
--   dead. The room cron was removed out-of-band (0015 comment); we unschedule
--   it defensively in case a fresh DB still carries it.
--
-- Re-runnable: idempotent drops + guarded unschedule.
-- ============================================================================

-- 1. Armwrestling tables (stats before matches — matches hold no FK to stats).
drop table if exists public.armwrestling_stats;
drop table if exists public.armwrestling_matches;

-- 2. Orphaned room RPCs (the `rooms` table was dropped in 0011).
drop function if exists public.list_rooms();
drop function if exists public.list_my_rooms();
drop function if exists public.join_room(uuid);
drop function if exists public.leave_room(uuid);
drop function if exists public.get_room_stats(uuid);
drop function if exists public.create_user_room(text, text, boolean);
drop function if exists public.delete_own_room(uuid);
drop function if exists public.send_room_message(uuid, text);
drop function if exists public.delete_own_public_message(uuid);
drop function if exists public.expire_temporary_rooms();
-- admin_upsert_builtin_room (0006) references the dropped `rooms` table too.
drop function if exists public.admin_upsert_builtin_room(text, text, text, boolean);

-- 3. Defensive unschedule of the (already-removed) temporary-rooms cron.
do $$
begin
  if exists (
    select 1 from cron.job where jobname = 'junglechat-expire-temp-rooms'
  ) then
    perform cron.unschedule('junglechat-expire-temp-rooms');
  end if;
end $$;
