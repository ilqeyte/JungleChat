-- ============================================================================
-- JUNGLECHAT — 0035_official_message_and_delete_fixes.sql
--
-- 1. OFFICIAL SENDER LABEL: admin (Adam) support messages now notify with
--    kind 'official_message' instead of 'new_message'. The push worker maps
--    that kind to the fixed text "Adam sent you a message." — a static
--    server-side label, no Animal IDs (charter rule 8 intact).
--
-- 2. ADMIN DELETE FIX: admin_delete_user died at runtime with
--    "operator does not exist: character varying = uuid" on
--    auth.refresh_tokens (this project's GoTrue schema stores token user
--    ids as varchar). Cast explicitly. This is why user deletion kept
--    failing after the earlier gate/param fixes.
--
-- 3. SAME BUG in process_inactivity (0007): the 90-day inactivity cleanup
--    would fail on its first victim with the identical varchar/uuid
--    mismatch. Cast fixed so the nightly cron actually deletes.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1 + 2. admin_send_support_message + admin_delete_user
-- (bodies from 0030; only the notify kind and the token delete changed)
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
  -- auth.sessions.user_id is uuid; auth.refresh_tokens.user_id is VARCHAR
  -- in this project's GoTrue schema — hence the explicit cast.
  delete from auth.sessions       where user_id = p_user_id;
  delete from auth.refresh_tokens where user_id = p_user_id::text;

  perform private.admin_audit('user.soft_deleted',
    jsonb_build_object('target', p_user_id,
                       'undo_deadline', now() + interval '7 days'));
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. process_inactivity — same varchar/uuid fix on the refresh_tokens delete.
-- Body otherwise identical to 0007.
-- ----------------------------------------------------------------------------
create or replace function public.process_inactivity(p_batch int default 500)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r          record;
  v_days     int;
  v_deleted  int := 0;
begin
  -- Pass 1: warnings (only for accounts still alive).
  for r in
    select p.id, p.inactivity_warning_sent,
           extract(day from now() - p.last_active_at)::int as days_idle
      from public.profiles p
     where p.deleted_at is null
       and p.last_active_at < now() - interval '80 days'
     limit p_batch
  loop
    if r.days_idle >= 89 then
      if r.inactivity_warning_sent < 89 then
        insert into public.notifications (user_id, kind, payload)
        values (r.id, 'inactivity_warning',
                jsonb_build_object('days_left', greatest(90 - r.days_idle, 0)));
        update public.profiles set inactivity_warning_sent = 89 where id = r.id;
      end if;
    elsif r.days_idle >= 85 then
      if r.inactivity_warning_sent < 85 then
        insert into public.notifications (user_id, kind, payload)
        values (r.id, 'inactivity_warning', jsonb_build_object('days_left', 5));
        update public.profiles set inactivity_warning_sent = 85 where id = r.id;
      end if;
    else
      if r.inactivity_warning_sent < 80 then
        insert into public.notifications (user_id, kind, payload)
        values (r.id, 'inactivity_warning', jsonb_build_object('days_left', 10));
        update public.profiles set inactivity_warning_sent = 80 where id = r.id;
      end if;
    end if;
  end loop;

  -- Pass 2: deletion of accounts idle >= 90 days.
  for r in
    select p.id, a.animal, a.number
      from public.profiles p
      left join public.animal_id a on a.user_id = p.id
     where p.deleted_at is null
       and p.last_active_at < now() - interval '90 days'
     limit p_batch
  loop
    delete from auth.sessions       where user_id = r.id;
    delete from auth.refresh_tokens where user_id = r.id::text;

    -- Release the Animal ID BEFORE deleting the user row (animal_id.user_id is
    -- ON DELETE SET NULL; explicit release also stamps released_at).
    if r.animal is not null then
      update public.animal_id
         set released_at = now(), user_id = null
       where animal = r.animal and number = r.number;
    end if;

    insert into public.security_events (event, details)
    values ('account.inactivity_deleted', jsonb_build_object('user', r.id));

    delete from auth.users where id = r.id;   -- cascades everywhere else
    v_deleted := v_deleted + 1;
  end loop;

  return v_deleted;
end;
$$;

-- Privileges unchanged, kept explicit.
revoke all on function public.admin_send_support_message(uuid,text) from public, anon;
grant execute on function public.admin_send_support_message(uuid,text) to authenticated;
revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;
revoke execute on function public.process_inactivity(int) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- Backfill: relabel EXISTING admin-sent message notifications so history
-- reads "Adam sent you a message." too. Guarded: only valid-UUID payloads
-- (an old dev row carries 'latency-test'), only rows whose conversation has
-- a message from an admin sent no later than the notification.
-- ----------------------------------------------------------------------------
update public.notifications n
   set kind = 'official_message'
 where n.kind = 'new_message'
   and (n.payload->>'conversation_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   and exists (
     select 1
       from public.direct_messages dm
       join public.conversations c on c.id = (n.payload->>'conversation_id')::uuid
      where dm.sender_id in (select user_id from public.admin_roles)
        and dm.created_at <= n.created_at
   );

