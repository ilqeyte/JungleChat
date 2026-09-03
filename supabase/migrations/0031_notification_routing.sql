-- ============================================================================
-- JUNGLECHAT — 0031_notification_routing.sql
--
-- Notification deep-linking + the group-invite ACCEPT fix.
--
--   1. accept_group_invitation (019) selected TWO columns (kind, payload)
--      into ONE jsonb variable, which raises a runtime error on every call
--      — that is why ACCEPT always failed and only IGNORE worked. Rewritten
--      with separate variables. Now returns the joined group_id so the
--      client can open the group straight after joining. Hardened with
--      set search_path = '' (it is security definer) and explicit grants
--      (019 relied on the default PUBLIC execute).
--
--   2. send_group_message never notified anyone, so group messages produced
--      no in-app notification and no push — nothing could deep-link into a
--      group. Adds a per-member fan-out of kind 'group_message' with a
--      payload of {"group_id"} ONLY (charter rule 8: no room names, no
--      message previews, no Animal IDs in notifications). Also hardened
--      with set search_path = '' + explicit grants.
--
--   3. respond_talk_request notified 'talk_accepted' with an empty payload,
--      so the client could not route to the conversation it just created.
--      The payload now carries conversation_id. Logic otherwise unchanged.
--
--   4. reject_group_invitation: same hardening (search_path + grants).
--
--   5. Partial index for the unread-badge / feed queries.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. accept_group_invitation — fixed + returns group_id
-- ----------------------------------------------------------------------------
drop function if exists public.accept_group_invitation(uuid);
create or replace function public.accept_group_invitation(p_notification_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind     text;
  v_payload  jsonb;
  v_group_id uuid;
  v_me       uuid := auth.uid();
begin
  select kind, payload into v_kind, v_payload
    from public.notifications
   where id = p_notification_id
     and user_id = v_me;

  if v_kind is null then
    raise exception 'NOTIFICATION_NOT_FOUND';
  end if;
  if v_kind <> 'group_invitation' then
    raise exception 'INVALID_NOTIFICATION_KIND';
  end if;

  v_group_id := (v_payload->>'group_id')::uuid;
  if v_group_id is null then
    raise exception 'INVALID_NOTIFICATION_KIND';
  end if;

  if not exists (select 1 from public.groups where id = v_group_id) then
    raise exception 'GROUP_NOT_FOUND';
  end if;

  insert into public.group_members (group_id, user_id, role)
  values (v_group_id, v_me, 'member')
  on conflict do nothing;

  delete from public.notifications where id = p_notification_id;

  return v_group_id;
end;
$$;

revoke all on function public.accept_group_invitation(uuid) from public, anon;
grant execute on function public.accept_group_invitation(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. reject_group_invitation — hardening only, behavior unchanged
-- ----------------------------------------------------------------------------
create or replace function public.reject_group_invitation(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.notifications
   where id = p_notification_id
     and user_id = auth.uid()
     and (payload->>'kind') = 'group_invitation';
end;
$$;

revoke all on function public.reject_group_invitation(uuid) from public, anon;
grant execute on function public.reject_group_invitation(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. send_group_message — adds the group_message notification fan-out
-- ----------------------------------------------------------------------------
create or replace function public.send_group_message(
  p_group_id uuid,
  p_content  text
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
  v_trimmed := trim(p_content);

  if char_length(v_trimmed) < 1 or char_length(v_trimmed) > 1000 then
    raise exception 'INVALID_MESSAGE_LENGTH';
  end if;

  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_MEMBER';
  end if;

  perform private.rate_limit('group_msg', auth.uid()::text || ':' || p_group_id::text, 60, interval '10 minutes');

  insert into public.group_messages (group_id, sender_id, content)
  values (p_group_id, auth.uid(), v_trimmed)
  returning id into v_msg_id;

  update public.groups set updated_at = now() where id = p_group_id;

  -- Fan out: one row per other member. Payload carries the group UUID ONLY
  -- (routing key, never rendered) — charter rule 8.
  insert into public.notifications (user_id, kind, payload)
  select gm.user_id, 'group_message', jsonb_build_object('group_id', p_group_id)
    from public.group_members gm
   where gm.group_id = p_group_id
     and gm.user_id <> auth.uid();

  return v_msg_id;
end;
$$;

revoke all on function public.send_group_message(uuid, text) from public, anon;
grant execute on function public.send_group_message(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. respond_talk_request — talk_accepted payload gains conversation_id
-- ----------------------------------------------------------------------------
create or replace function public.respond_talk_request(p_request uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   uuid := auth.uid();
  v_req  public.talk_requests%rowtype;
  v_conv uuid;
begin
  perform private.ensure_active_account();
  perform private.client_rate_limit('respond_request', 60, interval '10 minutes');
  perform private.touch_activity();

  select * into v_req
    from public.talk_requests
   where id = p_request
     and target_id = v_me
   for update;

  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.status <> 'pending' or v_req.expires_at < now() then
    raise exception 'REQUEST_NOT_ACTIVE';
  end if;

  update public.talk_requests
     set status = case when p_accept then 'accepted' else 'denied' end,
         responded_at = now()
   where id = v_req.id;

  if p_accept then
    insert into public.conversations (user_a, user_b)
    values (least(v_req.requester_id, v_req.target_id),
            greatest(v_req.requester_id, v_req.target_id))
    on conflict (user_a, user_b) do nothing
    returning id into v_conv;

    if v_conv is null then
      select c.id into v_conv
        from public.conversations c
       where c.user_a = least(v_req.requester_id, v_req.target_id)
         and c.user_b = greatest(v_req.requester_id, v_req.target_id);
    end if;

    perform private.notify(v_req.requester_id, 'talk_accepted',
      jsonb_build_object('conversation_id', v_conv));
  end if;
end;
$$;

-- Privileges were already correct for respond_talk_request (0004); keep them
-- explicit here so the rewrite can never silently widen access.
revoke all on function public.respond_talk_request(uuid, boolean) from public, anon;
grant execute on function public.respond_talk_request(uuid, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Unread-feed index
-- ----------------------------------------------------------------------------
create index if not exists notifications_unread_idx
  on public.notifications (user_id) where read_at is null;
