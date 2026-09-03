-- ============================================================================
-- JUNGLECHAT — 0005_messaging_functions.sql
--
-- Rooms (join/leave/stats), public room messaging, private chat messaging.
-- Authorization is re-derived from the database on every call — never from
-- client-supplied membership, ownership or role claims.
-- ============================================================================

-- ============================================================================
-- ROOMS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- list_rooms — visible rooms + whether I am a member. Identities never leak.
-- ----------------------------------------------------------------------------
create or replace function public.list_rooms()
returns table (
  id            uuid,
  slug          text,
  name          text,
  description   text,
  kind          public.room_kind,
  is_private    boolean,
  is_member     boolean,
  member_count  bigint,
  expires_at    timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.slug, r.name, r.description, r.kind, r.is_private,
         exists (select 1 from public.room_members m
                  where m.room_id = r.id and m.user_id = auth.uid()),
         (select count(*)::bigint from public.room_members m2 where m2.room_id = r.id),
         r.expires_at
    from public.rooms r
   where r.is_active
     and (r.expires_at is null or r.expires_at > now())
     and (
       r.kind in ('builtin', 'temporary')
       or not r.is_private
       or r.owner_id = auth.uid()
       or exists (select 1 from public.room_members m3
                   where m3.room_id = r.id and m3.user_id = auth.uid())
     )
   order by r.kind asc, r.created_at asc;
$$;

create or replace function public.list_my_rooms()
returns table (
  id           uuid,
  slug         text,
  name         text,
  description  text,
  kind         public.room_kind,
  expires_at   timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.slug, r.name, r.description, r.kind, r.expires_at
    from public.rooms r
    join public.room_members m on m.room_id = r.id and m.user_id = auth.uid()
   where r.is_active
     and (r.expires_at is null or r.expires_at > now())
   order by m.joined_at desc;
$$;

-- ----------------------------------------------------------------------------
-- join_room / leave_room — visibility re-checked server-side.
-- ----------------------------------------------------------------------------
create or replace function public.join_room(p_room uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.rooms%rowtype;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('room_join', coalesce(auth.uid()::text, private.client_ip()), 30, interval '10 minutes');
  perform private.touch_activity();

  select * into r from public.rooms where id = p_room;
  if r.id is null
     or not r.is_active
     or (r.expires_at is not null and r.expires_at <= now()) then
    raise exception 'ROOM_UNAVAILABLE';
  end if;

  if r.kind = 'user' and r.is_private and r.owner_id <> auth.uid() then
    raise exception 'ROOM_PRIVATE';
  end if;

  insert into public.room_members (room_id, user_id)
  values (p_room, auth.uid())
  on conflict do nothing;
end;
$$;

create or replace function public.leave_room(p_room uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.room_members
   where room_id = p_room and user_id = auth.uid();
$$;

-- ----------------------------------------------------------------------------
-- get_room_stats — "N animals here". Returns ONLY a count, never identities.
-- ----------------------------------------------------------------------------
create or replace function public.get_room_stats(p_room uuid)
returns table (animal_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::bigint
    from public.room_members m
   where m.room_id = p_room
     and exists (
       select 1 from public.rooms r
        where r.id = m.room_id
          and r.is_active
          and (r.expires_at is null or r.expires_at > now())
          and (
            r.kind in ('builtin', 'temporary')
            or not r.is_private
            or r.owner_id = auth.uid()
            or exists (select 1 from public.room_members mm
                        where mm.room_id = r.id and mm.user_id = auth.uid())
          )
     );
$$;

-- ----------------------------------------------------------------------------
-- create_user_room — optional MVP feature; ownership enforced server-side.
-- ----------------------------------------------------------------------------
create or replace function public.create_user_room(
  p_name        text,
  p_description text default '',
  p_is_private  boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('room_create', coalesce(auth.uid()::text, private.client_ip()), 3, interval '24 hours');
  perform private.touch_activity();

  p_name := btrim(coalesce(p_name, ''));
  if char_length(p_name) < 1 or char_length(p_name) > 60 then
    raise exception 'INVALID_ROOM_NAME';
  end if;
  if char_length(coalesce(p_description, '')) > 280 then
    raise exception 'INVALID_ROOM_DESCRIPTION';
  end if;

  insert into public.rooms (slug, name, description, kind, is_private, owner_id, created_by)
  values (
    left(md5(gen_random_uuid()::text), 12),   -- opaque slug, not user-chosen
    p_name, coalesce(p_description, ''), 'user', coalesce(p_is_private, false),
    auth.uid(), auth.uid()
  )
  returning id into v_id;

  insert into public.room_members (room_id, user_id) values (v_id, auth.uid());
  return v_id;
end;
$$;

create or replace function public.delete_own_room(p_room uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.rooms
   where id = p_room
     and kind = 'user'
     and owner_id = auth.uid();
end;
$$;

-- ============================================================================
-- PUBLIC ROOM MESSAGING
-- ============================================================================

-- ----------------------------------------------------------------------------
-- send_room_message — full gate: account status (muted blocks PUBLIC posting),
-- room visible/active/unexpired, real membership, content limits, rate caps.
-- ----------------------------------------------------------------------------
create or replace function public.send_room_message(p_room uuid, p_content text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_status public.account_status;
begin
  perform private.client_rate_limit('msg_global', 60, interval '10 minutes');
  perform private.rate_limit('msg_room',
    coalesce(auth.uid()::text, private.client_ip()) || '|' || coalesce(p_room::text, ''), 
    20, interval '1 minute');

  select status into v_status from public.profiles where id = auth.uid();
  if v_status is null then
    raise exception 'ACCOUNT_NOT_FOUND';
  end if;
  if v_status in ('suspended', 'banned') then
    raise exception 'ACCOUNT_RESTRICTED';
  end if;
  if v_status = 'muted' then
    raise exception 'MUTED_PUBLIC_POSTING';
  end if;

  p_content := btrim(coalesce(p_content, ''));
  if char_length(p_content) < 1 or char_length(p_content) > 1000 then
    raise exception 'INVALID_MESSAGE';
  end if;

  if not exists (
    select 1
      from public.rooms r
      join public.room_members m on m.room_id = r.id and m.user_id = auth.uid()
     where r.id = p_room
       and r.is_active
       and (r.expires_at is null or r.expires_at > now())
  ) then
    raise exception 'ROOM_NOT_JOINED';
  end if;

  insert into public.messages (room_id, sender_id, content)
  values (p_room, auth.uid(), p_content)
  returning id into v_id;

  perform private.touch_activity();
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- delete_own_public_message — soft delete; only your own.
-- ----------------------------------------------------------------------------
create or replace function public.delete_own_public_message(p_message uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.messages
     set deleted_at = now(), deleted_by = auth.uid()
   where id = p_message
     and sender_id = auth.uid()
     and deleted_at is null;
end;
$$;

-- ============================================================================
-- PRIVATE CHAT MESSAGING
-- ============================================================================

-- ----------------------------------------------------------------------------
-- send_direct_message — participants only; blocked pairs are dead ends here.
-- ----------------------------------------------------------------------------

create or replace function public.send_direct_message(p_conversation uuid, p_content text)
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

  insert into public.direct_messages (conversation_id, sender_id, content)
  values (p_conversation, auth.uid(), p_content)
  returning id into v_id;

  update public.conversations
     set last_message_at = now()
   where id = p_conversation;

  -- Privacy-safe: payload carries ONLY the conversation id to tap into.
  perform private.notify(v_other, 'new_message', jsonb_build_object('conversation_id', p_conversation));
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- delete_conversation — documented policy: leaving soft-deletes the thread
-- for BOTH participants. Server-side, participant-only.
-- ----------------------------------------------------------------------------
create or replace function public.delete_conversation(p_conversation uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
begin
  if not exists (
    select 1 from public.conversations c
     where c.id = p_conversation
       and (c.user_a = v_me or c.user_b = v_me)
  ) then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  update public.direct_messages
     set deleted_at = now(), deleted_by = v_me
   where conversation_id = p_conversation and deleted_at is null;

  delete from public.mutes
   where user_id = v_me and scope = 'conversation' and scope_id = p_conversation::text;
end;
$$;

-- ============================================================================
-- PRIVILEGES — authenticated only, never anon.
-- ============================================================================
revoke execute on function public.list_rooms()                        from public, anon;
revoke execute on function public.list_my_rooms()                     from public, anon;
revoke execute on function public.join_room(uuid)                     from public, anon;
revoke execute on function public.leave_room(uuid)                    from public, anon;
revoke execute on function public.get_room_stats(uuid)                from public, anon;
revoke execute on function public.create_user_room(text,text,boolean) from public, anon;
revoke execute on function public.delete_own_room(uuid)               from public, anon;
revoke execute on function public.send_room_message(uuid,text)        from public, anon;
revoke execute on function public.delete_own_public_message(uuid)     from public, anon;
revoke execute on function public.send_direct_message(uuid,text)      from public, anon;
revoke execute on function public.delete_conversation(uuid)           from public, anon;

grant execute on function public.list_rooms()                        to authenticated;
grant execute on function public.list_my_rooms()                     to authenticated;
grant execute on function public.join_room(uuid)                     to authenticated;
grant execute on function public.leave_room(uuid)                    to authenticated;
grant execute on function public.get_room_stats(uuid)                to authenticated;
grant execute on function public.create_user_room(text,text,boolean) to authenticated;
grant execute on function public.delete_own_room(uuid)               to authenticated;
grant execute on function public.send_room_message(uuid,text)        to authenticated;
grant execute on function public.delete_own_public_message(uuid)     to authenticated;
grant execute on function public.send_direct_message(uuid,text)      to authenticated;
grant execute on function public.delete_conversation(uuid)           to authenticated;
