-- ============================================================================
-- JUNGLECHAT — 0011_remove_rooms.sql  (APPLIED TO PRODUCTION VIA MCP)
-- Operator decision: the entire rooms system (public rooms, room chat,
-- room creation, room member directories) was removed.
-- Kept: private chat, talk requests, notifications, game, reports (minus
-- message/room targets), audit.
-- ============================================================================
drop table if exists public.messages cascade;
drop table if exists public.room_members cascade;
drop table if exists public.rooms cascade;
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime drop table public.messages;
    alter publication supabase_realtime drop table public.rooms;
  end if;
exception when others then null;
end;
$$;