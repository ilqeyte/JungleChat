-- 0306 — Message client ids + idempotent send (item #6 / Phase 5).
--
-- Bug B9: optimistic send currently reconciles by content matching
-- (priorSameCount). Sending the same text twice in a window, or interleaved
-- edits, can double-render or drop a bubble. Fix: every send carries a stable
-- client-generated UUID; the bubble is keyed by it, and the insert is
-- idempotent via ON CONFLICT DO NOTHING so a retry after a timeout returns the
-- existing row instead of duplicating. This is what makes the app safe on a
-- flaky link.
--
-- The unique index is PARTIAL (where client_msg_id is not null) so legacy
-- clients that pass null keep inserting normally — no collision risk, and old
-- installs degrade to a generic error rather than a crash.

-- ── Schema ────────────────────────────────────────────────────────────────────
alter table public.direct_messages add column client_msg_id uuid;
alter table public.group_messages  add column client_msg_id uuid;

create unique index if not exists dm_client_msg_uniq
  on public.direct_messages (conversation_id, sender_id, client_msg_id)
  where client_msg_id is not null;

create unique index if not exists gm_client_msg_uniq
  on public.group_messages (group_id, sender_id, client_msg_id)
  where client_msg_id is not null;

-- ── send_direct_message: accept p_client_msg_id, dedupe on conflict ─────────────
create or replace function public.send_direct_message(
  p_conversation   uuid,
  p_content        text,
  p_reply_to       uuid default null,
  p_client_msg_id  uuid default null
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
  perform private.ensure_active_account();
  perform private.rate_limit('dm_send', coalesce(auth.uid()::text, private.client_ip()), 60, interval '10 minutes');
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

  -- Blocking kills messaging in BOTH directions, regardless of who blocked.
  if private.blocked_between(auth.uid(), v_other) then
    raise exception 'MESSAGING_BLOCKED';
  end if;

  -- Reply target: same thread, exists, not deleted.
  if p_reply_to is not null and not exists (
    select 1 from public.direct_messages r
     where r.id = p_reply_to
       and r.conversation_id = p_conversation
       and r.deleted_at is null
  ) then
    raise exception 'INVALID_REPLY';
  end if;

  -- Idempotent insert: a retry with the same client_msg_id returns the
  -- existing row's id (DO UPDATE SET content = excluded.content is a no-op
  -- write that still returns the surviving row).
  insert into public.direct_messages
    (conversation_id, sender_id, content, reply_to_id, client_msg_id)
  values (p_conversation, auth.uid(), p_content, p_reply_to, p_client_msg_id)
  on conflict (conversation_id, sender_id, client_msg_id)
    where client_msg_id is not null
  do update set content = excluded.content
  returning id into v_id;

  update public.conversations
     set last_message_at = now()
   where id = p_conversation;

  -- Privacy-safe: payload carries ONLY the conversation id to tap into.
  perform private.notify(v_other, 'new_message', jsonb_build_object('conversation_id', p_conversation));
  return v_id;
end;
$$;

-- ── send_group_message: accept p_client_msg_id, dedupe on conflict ──────────────
create or replace function public.send_group_message(
  p_group_id       uuid,
  p_content        text,
  p_reply_to       uuid default null,
  p_client_msg_id  uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_msg_id uuid;
  v_trimmed text;
begin
  perform private.ensure_active_account();
  perform private.touch_activity();

  v_trimmed := btrim(coalesce(p_content, ''));

  -- Validate content
  if char_length(v_trimmed) < 1 or char_length(v_trimmed) > 1000 then
    raise exception 'INVALID_MESSAGE_LENGTH';
  end if;

  -- Verify membership
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_MEMBER';
  end if;

  -- Rate limit: 60 messages per 10 minutes per user per group
  perform private.rate_limit('group_msg', auth.uid()::text || ':' || p_group_id::text, 60, interval '10 minutes');

  -- Reply target: same group, exists, not deleted.
  if p_reply_to is not null and not exists (
    select 1 from public.group_messages r
     where r.id = p_reply_to
       and r.group_id = p_group_id
       and r.deleted_at is null
  ) then
    raise exception 'INVALID_REPLY';
  end if;

  -- Idempotent insert (same dedup semantics as DM).
  insert into public.group_messages
    (group_id, sender_id, content, reply_to_id, client_msg_id)
  values (p_group_id, auth.uid(), v_trimmed, p_reply_to, p_client_msg_id)
  on conflict (group_id, sender_id, client_msg_id)
    where client_msg_id is not null
  do update set content = excluded.content
  returning id into v_msg_id;

  -- Update group timestamp
  update public.groups set updated_at = now() where id = p_group_id;

  -- Fan-out: one row per other member. Payload carries the group UUID ONLY
  -- (routing key, never rendered) — charter rule 8.
  insert into public.notifications (user_id, kind, payload)
  select gm.user_id, 'group_message', jsonb_build_object('group_id', p_group_id)
    from public.group_members gm
   where gm.group_id = p_group_id
     and gm.user_id <> auth.uid();

  return v_msg_id;
end;
$$;

-- Keep grants in lock-step with the prior definitions.
revoke execute on function public.send_direct_message(uuid, text, uuid, uuid) from public, anon;
grant  execute on function public.send_direct_message(uuid, text, uuid, uuid) to authenticated;
revoke execute on function public.send_group_message(uuid, text, uuid, uuid)  from public, anon;
grant  execute on function public.send_group_message(uuid, text, uuid, uuid)  to authenticated;

-- ── admin_send_support_message: same idempotent client_msg_id treatment ──────
-- (official channel; audited server-side). Based on the 0039 definition.
create or replace function public.admin_send_support_message(
  p_conversation   uuid,
  p_content        text,
  p_reply_to       uuid default null,
  p_client_msg_id  uuid default null
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

  -- Reply target: same thread, exists, not deleted (same rule as users).
  if p_reply_to is not null and not exists (
    select 1 from public.direct_messages r
     where r.id = p_reply_to
       and r.conversation_id = p_conversation
       and r.deleted_at is null
  ) then
    raise exception 'INVALID_REPLY';
  end if;

  insert into public.direct_messages
    (conversation_id, sender_id, content, reply_to_id, client_msg_id)
  values (p_conversation, auth.uid(), p_content, p_reply_to, p_client_msg_id)
  on conflict (conversation_id, sender_id, client_msg_id)
    where client_msg_id is not null
  do update set content = excluded.content
  returning id into v_id;

  update public.conversations
     set last_message_at = now()
   where id = p_conversation;

  -- Official sender: distinct kind so the client + push worker can label
  -- it "Adam sent you a message." Payload carries the conversation UUID
  -- only (routing key, never rendered — charter rule 8).
  perform private.notify(v_other, 'official_message',
    jsonb_build_object('conversation_id', p_conversation));

  perform private.admin_audit('support_chat.message_sent',
    jsonb_build_object('conversation', p_conversation, 'to', v_other));
  return v_id;
end;
$$;

revoke execute on function public.admin_send_support_message(uuid, text, uuid, uuid) from public, anon;
grant  execute on function public.admin_send_support_message(uuid, text, uuid, uuid) to authenticated;
