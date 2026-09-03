-- 0309 — Drop the Postgres-backed typing indicator (Bug B6).
--
-- Typing is now carried over the Realtime Broadcast channel
-- (app/lib/services/realtime_chat.dart): sendTypingConversation /
-- onTypingConversation. That path does zero DB writes, zero RLS evaluation,
-- and no `conversations` row churn per keystroke, so it is strictly better
-- than the old polling-on-a-timestamp design.
--
-- The client already dropped the code that called these (chat_service.dart
-- removed setTyping + watchConversation during the Phase 5.1 transport work),
-- so the `set_typing` SECURITY DEFINER function and its `typing_a_until` /
-- `typing_b_until` columns are dead. Remove them so no dangling function or
-- stale columns linger. Idempotent (IF EXISTS) for safe re-runs.

begin;

drop function if exists public.set_typing(uuid);

alter table public.conversations
  drop column if exists typing_a_until,
  drop column if exists typing_b_until;

commit;
