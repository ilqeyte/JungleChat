-- 0307 — Disappearing messages that actually work (item #7 / Phase 6, B1).
--
-- Bug B1: cleanup_auto_delete_messages() exists but the pg_cron job that
-- should call it was NEVER scheduled, so the timer is stored and displayed
-- but expiry silently never happens.
--
-- Fix: an explicit per-message expires_at, enforced at READ time by RLS so a
-- late or offline sweeper cannot leak an expired message, plus the sweeper
-- cron job 020 forgot to create. Changing the timer applies to NEW messages
-- only (surfaced in the client dialog).

-- ── 1. Columns ────────────────────────────────────────────────────────────────
alter table public.direct_messages add column expires_at timestamptz;
alter table public.group_messages  add column expires_at timestamptz;
comment on column public.direct_messages.expires_at is
  'Server-set. now() + conversation.auto_delete_interval. Null = no expiry. '
  'RLS hides rows once this is in the past; clients never decide expiry.';
comment on column public.group_messages.expires_at is
  'Server-set. now() + group.auto_delete_interval. Null = no expiry.';

-- ── 2. RLS: hide expired rows on SELECT (the real enforcement) ───────────────
drop policy if exists dm_select_participant on public.direct_messages;
create policy dm_select_participant
  on public.direct_messages for select
  to authenticated
  using (
    deleted_at is null
    and (expires_at is null or expires_at > now())
    and exists (
      select 1 from public.conversations c
       where c.id = direct_messages.conversation_id
         and (c.user_a = auth.uid() or c.user_b = auth.uid())
    )
  );

drop policy if exists "group_messages_select_member" on public.group_messages;
create policy "group_messages_select_member" on public.group_messages
  for select using (
    public.is_group_member(group_id, auth.uid())
    and (expires_at is null or expires_at > now())
  );

-- ── 3. Send RPCs: stamp expires_at server-side (never client-supplied) ────────
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
  v_expires timestamptz := (
    select now() + c.auto_delete_interval
      from public.conversations c
     where c.id = p_conversation
       and c.auto_delete_interval is not null
  );
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

  if private.blocked_between(auth.uid(), v_other) then
    raise exception 'MESSAGING_BLOCKED';
  end if;

  if p_reply_to is not null and not exists (
    select 1 from public.direct_messages r
     where r.id = p_reply_to
       and r.conversation_id = p_conversation
       and r.deleted_at is null
  ) then
    raise exception 'INVALID_REPLY';
  end if;

  insert into public.direct_messages
    (conversation_id, sender_id, content, reply_to_id, client_msg_id, expires_at)
  values (p_conversation, auth.uid(), p_content, p_reply_to, p_client_msg_id, v_expires)
  on conflict (conversation_id, sender_id, client_msg_id)
    where client_msg_id is not null
  do update set content = excluded.content
  returning id into v_id;

  update public.conversations set last_message_at = now() where id = p_conversation;

  perform private.notify(v_other, 'new_message', jsonb_build_object('conversation_id', p_conversation));
  return v_id;
end;
$$;

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
  v_expires timestamptz := (
    select now() + g.auto_delete_interval
      from public.groups g
     where g.id = p_group_id
       and g.auto_delete_interval is not null
  );
begin
  perform private.ensure_active_account();
  perform private.touch_activity();

  v_trimmed := btrim(coalesce(p_content, ''));
  if char_length(v_trimmed) < 1 or char_length(v_trimmed) > 1000 then
    raise exception 'INVALID_MESSAGE_LENGTH';
  end if;

  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_MEMBER';
  end if;

  perform private.rate_limit('group_msg', auth.uid()::text || ':' || p_group_id::text, 60, interval '10 minutes');

  if p_reply_to is not null and not exists (
    select 1 from public.group_messages r
     where r.id = p_reply_to
       and r.group_id = p_group_id
       and r.deleted_at is null
  ) then
    raise exception 'INVALID_REPLY';
  end if;

  insert into public.group_messages
    (group_id, sender_id, content, reply_to_id, client_msg_id, expires_at)
  values (p_group_id, auth.uid(), v_trimmed, p_reply_to, p_client_msg_id, v_expires)
  on conflict (group_id, sender_id, client_msg_id)
    where client_msg_id is not null
  do update set content = excluded.content
  returning id into v_msg_id;

  update public.groups set updated_at = now() where id = p_group_id;

  insert into public.notifications (user_id, kind, payload)
  select gm.user_id, 'group_message', jsonb_build_object('group_id', p_group_id)
    from public.group_members gm
   where gm.group_id = p_group_id
     and gm.user_id <> auth.uid();

  return v_msg_id;
end;
$$;

revoke execute on function public.send_direct_message(uuid, text, uuid, uuid) from public, anon;
grant  execute on function public.send_direct_message(uuid, text, uuid, uuid) to authenticated;
revoke execute on function public.send_group_message(uuid, text, uuid, uuid)  from public, anon;
grant  execute on function public.send_group_message(uuid, text, uuid, uuid)  to authenticated;

-- ── 4. Backfill: rows in already-timed conversations/groups get expires_at
--       from their OWN creation time (consistent with how new messages expire). ─
update public.direct_messages dm
   set expires_at = dm.created_at + c.auto_delete_interval
  from public.conversations c
 where dm.conversation_id = c.id
   and c.auto_delete_interval is not null
   and dm.expires_at is null;

update public.group_messages gm
   set expires_at = gm.created_at + g.auto_delete_interval
  from public.groups g
 where gm.group_id = g.id
   and g.auto_delete_interval is not null
   and gm.expires_at is null;

-- ── 5. The sweeper 020 forgot: schedule it. RLS is the authority; this is
--       just bookkeeping (1-hour grace so a late cron tick never deletes
--       something still visible). ─────────────────────────────────────────────
create extension if not exists pg_cron;

select cron.schedule(
  'junglechat-expire-messages', '*/10 * * * *',
  $$ delete from public.direct_messages
       where expires_at is not null and expires_at < now() - interval '1 hour';
     delete from public.group_messages
       where expires_at is not null and expires_at < now() - interval '1 hour'; $$
);
