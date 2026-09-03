-- ============================================================================
-- JUNGLECHAT — 0030_admin_gate_and_param_fix.sql
--
-- Fixes the admin dashboard's "Message" and "Delete User" actions, which
-- failed for every admin:
--
--   1. GATE: five admin RPCs gated on private.is_admin(), which additionally
--      requires an MFA-elevated (aal2) session. The Flutter client performs
--      password-only admin sign-in (no MFA challenge yet), so every call
--      raised NOT_ADMIN. admin_list_users / admin_suspend_user were already
--      re-gated on plain admin_roles membership by 0026 for exactly this
--      reason. This migration brings the remaining five in line with that
--      documented interim decision:
--        admin_open_support_chat, admin_mark_support_read,
--        admin_send_support_message, admin_delete_user,
--        admin_undo_delete_user
--      SECURITY NOTE: authorization still requires an explicit admin_roles
--      row verified server-side on every call — nothing is granted to the
--      public. Once the client implements MFA (aal2), move all of these
--      back to private.is_admin(). See docs/AUDIT-2026-08-30.md.
--
--   2. PARAM MISMATCH: the client calls admin_open_support_chat with
--      p_user_id, but the function's parameter was named p_user, so
--      PostgREST could not resolve the call even with a valid admin gate.
--      The parameter is renamed to p_user_id (matching every other admin
--      RPC); signatures/types are otherwise unchanged.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- admin_open_support_chat — param renamed p_user -> p_user_id; gate aligned
-- with 0026 (admin_roles row, no aal2 requirement yet).
-- Postgres cannot rename an input parameter via CREATE OR REPLACE, so the
-- old signature is dropped first (same arg types; grants are re-issued below).
-- ----------------------------------------------------------------------------
drop function if exists public.admin_open_support_chat(uuid);

create or replace function public.admin_open_support_chat(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   uuid;
  v_a    uuid;
  v_b    uuid;
  v_id   uuid;
  v_status public.account_status;
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  v_me := auth.uid();
  if p_user_id is null or p_user_id = v_me then
    raise exception 'INVALID_TARGET';
  end if;

  select status into v_status from public.profiles where id = p_user_id;
  if v_status is null or v_status = 'banned' then
    raise exception 'TARGET_NOT_FOUND';
  end if;

  v_a := least(v_me, p_user_id);
  v_b := greatest(v_me, p_user_id);

  insert into public.conversations (user_a, user_b)
  values (v_a, v_b)
  on conflict (user_a, user_b) do nothing
  returning id into v_id;

  if v_id is null then
    select c.id into v_id
      from public.conversations c
     where c.user_a = v_a and c.user_b = v_b;
  end if;

  perform private.admin_audit('support_chat.opened',
    jsonb_build_object('conversation', v_id, 'user', p_user_id));
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_mark_support_read — gate aligned with 0026. Body unchanged.
-- ----------------------------------------------------------------------------
create or replace function public.admin_mark_support_read(p_conversation uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.conversations c
     where c.id = p_conversation
       and (c.user_a = auth.uid() or c.user_b = auth.uid())
  ) then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  insert into private.support_reads (conversation_id, user_id, last_read_at)
  values (p_conversation, auth.uid(), now())
  on conflict (conversation_id, user_id)
  do update set last_read_at = now();
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_send_support_message — gate aligned with 0026. Body unchanged.
-- ----------------------------------------------------------------------------
create or replace function public.admin_send_support_message(
  p_conversation uuid,
  p_content text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_other uuid;
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  perform private.rate_limit('dm_send', auth.uid()::text, 60, interval '10 minutes');
  perform private.touch_activity();

  p_content := btrim(coalesce(p_content, ''));
  if char_length(p_content) < 1 or char_length(p_content) > 1000 then
    raise exception 'INVALID_MESSAGE';
  end if;

  select case when c.user_a = auth.uid() then c.user_b else c.user_a end
    into v_other
    from public.conversations c
   where c.id = p_conversation
     and (c.user_a = auth.uid() or c.user_b = auth.uid());

  if v_other is null then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  insert into public.direct_messages (conversation_id, sender_id, content)
  values (p_conversation, auth.uid(), p_content)
  returning id into v_id;

  update public.conversations
     set last_message_at = now()
   where id = p_conversation;

  perform private.notify(v_other, 'new_message',
    jsonb_build_object('conversation_id', p_conversation));

  perform private.admin_audit('support_chat.message_sent',
    jsonb_build_object('conversation', p_conversation, 'to', v_other));
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_delete_user — gate aligned with 0026. Body unchanged.
-- ----------------------------------------------------------------------------
create or replace function public.admin_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.profiles%rowtype;
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  if p_user_id is null or p_user_id = auth.uid() then
    raise exception 'INVALID_TARGET';
  end if;
  -- Admins are untouchable through every admin path.
  if exists (select 1 from public.admin_roles ar where ar.user_id = p_user_id) then
    raise exception 'TARGET_IS_ADMIN';
  end if;

  select * into v_target from public.profiles where id = p_user_id;
  if v_target.id is null then
    raise exception 'TARGET_NOT_FOUND';
  end if;
  -- Already deleted: idempotent success (undo remains available).
  if v_target.deleted_at is not null then
    return;
  end if;

  update public.profiles
     set deleted_at = now(),
         delete_undo_deadline = now() + interval '7 days',
         status = 'banned'
   where id = p_user_id;

  -- Kill every live session so the deletion takes effect immediately.
  delete from auth.sessions       where user_id = p_user_id;
  delete from auth.refresh_tokens where user_id = p_user_id;

  perform private.admin_audit('user.soft_deleted',
    jsonb_build_object('target', p_user_id,
                       'undo_deadline', now() + interval '7 days'));
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_undo_delete_user — gate aligned with 0026. Body unchanged.
-- ----------------------------------------------------------------------------
create or replace function public.admin_undo_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.profiles%rowtype;
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_user_id;
  if v_target.id is null or v_target.deleted_at is null then
    raise exception 'TARGET_NOT_DELETED';
  end if;
  if v_target.delete_undo_deadline is not null
     and v_target.delete_undo_deadline < now() then
    raise exception 'UNDO_WINDOW_EXPIRED';
  end if;

  update public.profiles
     set deleted_at = null,
         delete_undo_deadline = null,
         status = 'active'
   where id = p_user_id;

  perform private.admin_audit('user.soft_delete_undone',
    jsonb_build_object('target', p_user_id));
end;
$$;

-- ============================================================================
-- PRIVILEGES — authenticated only, never anon. The admin_roles gate inside
-- each function is the real authorization (0026 pattern).
-- ============================================================================
revoke execute on function public.admin_open_support_chat(uuid)          from public, anon, authenticated;
revoke execute on function public.admin_mark_support_read(uuid)          from public, anon, authenticated;
revoke execute on function public.admin_send_support_message(uuid,text)  from public, anon, authenticated;
revoke execute on function public.admin_delete_user(uuid)                from public, anon, authenticated;
revoke execute on function public.admin_undo_delete_user(uuid)           from public, anon, authenticated;

grant execute on function public.admin_open_support_chat(uuid)           to authenticated;
grant execute on function public.admin_mark_support_read(uuid)           to authenticated;
grant execute on function public.admin_send_support_message(uuid,text)   to authenticated;
grant execute on function public.admin_delete_user(uuid)                 to authenticated;
grant execute on function public.admin_undo_delete_user(uuid)            to authenticated;
