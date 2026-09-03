-- ============================================================================
-- JUNGLECHAT - 0038_community_reply_reactions.sql
--
-- 1) BUILT-IN COMMUNITY GROUPS
--    - groups.is_builtin flag + idempotent seed of the "Community" group
--      (creator = the admin_roles user, i.e. Adam).
--    - Open join/leave for everyone (Adam cannot leave his own community;
--      builtin groups never auto-dissolve).
--    - Any member may add others to a builtin group (server adds them
--      DIRECTLY and notifies with kind 'group_added', payload {group_id}
--      only — routing key, rule 8). Private groups keep the invitation
--      flow unchanged.
--    - Admin-only management RPCs (create / kick / dissolve / delete any
--      message), gated on admin_roles server-side.
-- 2) REPLIES: reply_to_id on both message tables, validated in the send
--    RPCs (same thread, exists, not deleted).
-- 3) REACTIONS (WhatsApp model): one reaction per user per message, upsert
--    via RPC, empty emoji = remove. Deny-by-default RLS: participants /
--    members read-only; writes only through RPCs. Tables are added to the
--    realtime publication for live updates on both sides.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1a. Builtin flag
-- ----------------------------------------------------------------------------
alter table public.groups
  add column if not exists is_builtin boolean not null default false;

-- ----------------------------------------------------------------------------
-- 1b. Seed the Community group (idempotent) — creator is Adam.
-- ----------------------------------------------------------------------------
do $$
declare
  v_admin uuid;
  v_group uuid;
begin
  select user_id into v_admin from public.admin_roles limit 1;
  if v_admin is null then
    -- Fresh install: no admin exists yet, so there is no Community group to
    -- seed. Skip. Migration 0300 later removes the built-in community concept
    -- entirely, so this seed is only relevant on the legacy project.
    return;
  end if;

  select id into v_group from public.groups where is_builtin limit 1;
  if v_group is null then
    insert into public.groups (name, creator_id, is_builtin)
    values ('Community', v_admin, true)
    returning id into v_group;
  end if;

  insert into public.group_members (group_id, user_id, role)
  values (v_group, v_admin, 'admin')
  on conflict (group_id, user_id) do nothing;
end $$;

-- ----------------------------------------------------------------------------
-- 2. Reply support — schema
-- ----------------------------------------------------------------------------
alter table public.direct_messages
  add column if not exists reply_to_id uuid
    references public.direct_messages(id) on delete set null;
alter table public.group_messages
  add column if not exists reply_to_id uuid
    references public.group_messages(id) on delete set null;

create index if not exists idx_dm_reply   on public.direct_messages(reply_to_id);
create index if not exists idx_gm_reply   on public.group_messages(reply_to_id);

-- ----------------------------------------------------------------------------
-- 3. Reactions — schema (denormalized thread key: simple RLS + realtime)
-- ----------------------------------------------------------------------------
create table if not exists public.direct_message_reactions (
  id              uuid primary key default gen_random_uuid(),
  message_id      uuid not null references public.direct_messages(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  emoji           text not null check (char_length(emoji) between 1 and 16),
  created_at      timestamptz not null default now(),
  unique (message_id, user_id)
);

create table if not exists public.group_message_reactions (
  id         uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.group_messages(id) on delete cascade,
  group_id   uuid not null references public.groups(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  emoji      text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  unique (message_id, user_id)
);

create index if not exists idx_dmr_conv on public.direct_message_reactions(conversation_id);
create index if not exists idx_gmr_grp  on public.group_message_reactions(group_id);

alter table public.direct_message_reactions enable row level security;
alter table public.group_message_reactions  enable row level security;
alter table public.direct_message_reactions force row level security;
alter table public.group_message_reactions  force row level security;

-- Read: only thread participants / group members. Writes: RPCs only.
drop policy if exists "dmr_select_participant" on public.direct_message_reactions;
create policy "dmr_select_participant" on public.direct_message_reactions
  for select using (
    exists (
      select 1 from public.conversations c
       where c.id = direct_message_reactions.conversation_id
         and (c.user_a = auth.uid() or c.user_b = auth.uid())
    )
  );

drop policy if exists "gmr_select_member" on public.group_message_reactions;
create policy "gmr_select_member" on public.group_message_reactions
  for select using (
    public.is_group_member(group_message_reactions.group_id, auth.uid())
  );

grant select on public.direct_message_reactions to authenticated;
grant select on public.group_message_reactions  to authenticated;

-- Realtime for both sides (idempotent: skip if already in the publication).
do $$
begin
  begin
    alter publication supabase_realtime add table public.direct_message_reactions;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.group_message_reactions;
  exception when duplicate_object then null;
  end;
end $$;

-- Old 2-arg send overloads are dead code now that reply_to exists — remove
-- so calls can never silently bypass reply validation.
drop function if exists public.send_direct_message(uuid, text);
drop function if exists public.send_group_message(uuid, text);

-- ----------------------------------------------------------------------------
-- 1c. Builtin list / join / leave
-- ----------------------------------------------------------------------------
create or replace function public.list_builtin_groups()
returns table (
  id           uuid,
  name         text,
  member_count bigint,
  is_member    boolean,
  is_creator   boolean
)
language sql stable security definer set search_path = ''
as $$
  select g.id,
         g.name,
         (select count(*) from public.group_members gm where gm.group_id = g.id),
         exists (select 1 from public.group_members gm
                  where gm.group_id = g.id and gm.user_id = auth.uid()),
         (g.creator_id = auth.uid())
    from public.groups g
   where g.is_builtin
   order by g.created_at asc;
$$;

create or replace function public.join_builtin_group(p_group uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.ensure_active_account();

  if not exists (select 1 from public.groups where id = p_group and is_builtin) then
    raise exception 'GROUP_NOT_FOUND';
  end if;

  insert into public.group_members (group_id, user_id, role)
  values (p_group, auth.uid(), 'member')
  on conflict (group_id, user_id) do nothing;
end;
$$;

create or replace function public.leave_builtin_group(p_group uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.ensure_active_account();

  if not exists (select 1 from public.groups where id = p_group and is_builtin) then
    raise exception 'GROUP_NOT_FOUND';
  end if;

  -- Adam cannot leave his own community.
  if exists (select 1 from public.groups where id = p_group and creator_id = auth.uid()) then
    raise exception 'CREATOR_CANNOT_LEAVE';
  end if;

  delete from public.group_members
   where group_id = p_group and user_id = auth.uid();
end;
$$;

-- ----------------------------------------------------------------------------
-- 1d. add_group_members — builtin: any member adds DIRECTLY (+ 'group_added'
--     notification, routing key only). Private: unchanged invitation flow.
-- ----------------------------------------------------------------------------
create or replace function public.add_group_members(
    p_group_id   uuid,
    p_member_ids uuid[]
)
returns int as $$
declare
    v_member uuid;
    v_added  int := 0;
    v_group_name text;
    v_inviter_id uuid := auth.uid();
    v_inviter_animal text;
    v_inviter_display text;
    v_is_builtin boolean;
    v_cap int := 50;
begin
    select is_builtin into v_is_builtin from public.groups where id = p_group_id;
    if v_is_builtin is null then
        raise exception 'GROUP_NOT_FOUND';
    end if;

    -- Builtin: any MEMBER may add. Private: admin only.
    if v_is_builtin then
        if not public.is_group_member(p_group_id, v_inviter_id) then
            raise exception 'NOT_GROUP_MEMBER';
        end if;
        v_cap := 500;
    else
        if not public.is_group_admin(p_group_id, v_inviter_id) then
            raise exception 'NOT_GROUP_ADMIN';
        end if;
    end if;

    -- Member cap (500 builtin / 50 private)
    if (select count(*) from public.group_members where group_id = p_group_id)
       + coalesce(array_length(p_member_ids, 1), 0) > v_cap then
        raise exception 'GROUP_TOO_MANY_MEMBERS';
    end if;

    select name into v_group_name from public.groups where id = p_group_id;

    select animal, display_animal_id into v_inviter_animal, v_inviter_display
    from public.profiles where id = v_inviter_id;

    foreach v_member in array p_member_ids loop
        -- Skip if already a member
        if public.is_group_member(p_group_id, v_member) then
            continue;
        end if;

        -- Verify invitee exists and is active
        if not exists (
            select 1 from public.profiles
            where id = v_member and status = 'active' and deleted_at is null
        ) then
            continue;
        end if;

        -- Shadow-mode users opted out of social features: never added by others.
        if not (select open_to_talk from public.profiles where id = v_member) then
            continue;
        end if;

        -- Skip blocks in both directions.
        if private.blocked_between(v_inviter_id, v_member) then
            continue;
        end if;

        if v_is_builtin then
            -- DIRECT ADD (open community): user becomes a member now.
            insert into public.group_members (group_id, user_id, role)
            values (p_group_id, v_member, 'member')
            on conflict (group_id, user_id) do nothing;

            -- Routing-key-only payload (rule 8).
            perform private.notify(v_member, 'group_added', jsonb_build_object('group_id', p_group_id));
            v_added := v_added + 1;
        else
            -- PRIVATE GROUPS: invitation flow, unchanged. Requires an
            -- existing conversation between inviter and invitee.
            if not exists (
                select 1 from public.conversations
                where (user_a = v_inviter_id and user_b = v_member)
                   or (user_a = v_member and user_b = v_inviter_id)
            ) then
                continue;
            end if;

            insert into public.notifications (user_id, kind, payload)
            values (
                v_member,
                'group_invitation',
                jsonb_build_object(
                    'group_id', p_group_id,
                    'group_name', v_group_name,
                    'inviter_id', v_inviter_id,
                    'inviter_animal', v_inviter_animal,
                    'inviter_display', v_inviter_display
                )
            );
            v_added := v_added + 1;
        end if;
    end loop;

    return v_added;
end;
$$ language plpgsql security definer;

-- ----------------------------------------------------------------------------
-- 1e. remove_group_member — builtin groups NEVER auto-dissolve; creator
--     unremovable (existing rule); admin can still kick.
-- ----------------------------------------------------------------------------
create or replace function public.remove_group_member(
  p_group_id uuid,
  p_user_id  uuid
)
returns boolean as $$
begin
  if not public.is_group_admin(p_group_id, auth.uid()) and p_user_id != auth.uid() then
    raise exception 'NOT_GROUP_ADMIN';
  end if;

  -- Can't remove the creator
  if exists (
    select 1 from public.groups where id = p_group_id and creator_id = p_user_id
  ) and p_user_id != auth.uid() then
    raise exception 'CANNOT_REMOVE_CREATOR';
  end if;

  delete from public.group_members
  where group_id = p_group_id and user_id = p_user_id;

  -- Builtin groups are permanent — leaves never dissolve them.
  if exists (select 1 from public.groups where id = p_group_id and is_builtin) then
    return false;
  end if;

  -- If creator left, dissolve group (private groups only)
  if p_user_id = auth.uid() and exists (
    select 1 from public.groups where id = p_group_id and creator_id = auth.uid()
  ) then
    delete from public.groups where id = p_group_id;
    return true; -- group dissolved
  end if;

  -- If group has < 2 members, dissolve (private groups only)
  if (select count(*) from public.group_members where group_id = p_group_id) < 2 then
    delete from public.groups where id = p_group_id;
    return true;
  end if;

  return false;
end;
$$ language plpgsql security definer;

-- ----------------------------------------------------------------------------
-- 1f. Adam-only management RPCs (admin_roles gate, server-side).
-- ----------------------------------------------------------------------------
create or replace function public.admin_create_builtin_group(p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not exists (select 1 from public.admin_roles where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  p_name := btrim(coalesce(p_name, ''));
  if char_length(p_name) < 2 or char_length(p_name) > 50 then
    raise exception 'INVALID_GROUP_NAME';
  end if;

  insert into public.groups (name, creator_id, is_builtin)
  values (p_name, auth.uid(), true)
  returning id into v_id;

  insert into public.group_members (group_id, user_id, role)
  values (v_id, auth.uid(), 'admin')
  on conflict (group_id, user_id) do nothing;

  return v_id;
end;
$$;

create or replace function public.admin_kick_builtin_member(p_group uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_roles where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if not exists (select 1 from public.groups where id = p_group and is_builtin) then
    raise exception 'GROUP_NOT_FOUND';
  end if;
  if exists (select 1 from public.groups where id = p_group and creator_id = p_user) then
    raise exception 'CANNOT_REMOVE_CREATOR';
  end if;

  delete from public.group_members
   where group_id = p_group and user_id = p_user;
end;
$$;

create or replace function public.admin_dissolve_builtin_group(p_group uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_roles where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;
  if not exists (select 1 from public.groups where id = p_group and is_builtin) then
    raise exception 'GROUP_NOT_FOUND';
  end if;

  delete from public.groups where id = p_group; -- cascades members+messages
end;
$$;

create or replace function public.admin_delete_group_message(p_message uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_roles where user_id = auth.uid()) then
    raise exception 'NOT_ADMIN';
  end if;

  update public.group_messages m
     set content = '',
         deleted_at = now(),
         deleted_by = auth.uid()
   where m.id = p_message
     and m.deleted_at is null
     and exists (select 1 from public.groups g
                  where g.id = m.group_id and g.is_builtin);

  if not found then
    raise exception 'MESSAGE_NOT_DELETABLE';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. Send RPCs gain optional reply target (validated server-side).
-- ----------------------------------------------------------------------------
create or replace function public.send_direct_message(
  p_conversation uuid,
  p_content      text,
  p_reply_to     uuid default null
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

  insert into public.direct_messages (conversation_id, sender_id, content, reply_to_id)
  values (p_conversation, auth.uid(), p_content, p_reply_to)
  returning id into v_id;

  update public.conversations
     set last_message_at = now()
   where id = p_conversation;

  -- Privacy-safe: payload carries ONLY the conversation id to tap into.
  perform private.notify(v_other, 'new_message', jsonb_build_object('conversation_id', p_conversation));
  return v_id;
end;
$$;

create or replace function public.send_group_message(
  p_group_id uuid,
  p_content  text,
  p_reply_to uuid default null
)
returns uuid as $$
declare
  v_msg_id uuid;
  v_trimmed text;
begin
  v_trimmed := trim(p_content);

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

  -- Insert message
  insert into public.group_messages (group_id, sender_id, content, reply_to_id)
  values (p_group_id, auth.uid(), v_trimmed, p_reply_to)
  returning id into v_msg_id;

  -- Update group timestamp
  update public.groups set updated_at = now() where id = p_group_id;

  return v_msg_id;
end;
$$ language plpgsql security definer;

-- ----------------------------------------------------------------------------
-- 3. Reaction RPCs (WhatsApp model: one per user, upsert, empty = remove)
-- ----------------------------------------------------------------------------
create or replace function public.react_direct_message(p_message uuid, p_emoji text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_conv uuid;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('dm_react', coalesce(auth.uid()::text, private.client_ip()), 120, interval '10 minutes');

  select conversation_id into v_conv
    from public.direct_messages
   where id = p_message
     and deleted_at is null
     and (sender_id = auth.uid()
          or exists (select 1 from public.conversations c
                      where c.id = direct_messages.conversation_id
                        and (c.user_a = auth.uid() or c.user_b = auth.uid())));

  if v_conv is null then
    raise exception 'NOT_ALLOWED';
  end if;

  p_emoji := btrim(coalesce(p_emoji, ''));
  if p_emoji = '' then
    delete from public.direct_message_reactions
     where message_id = p_message and user_id = auth.uid();
    return;
  end if;
  if char_length(p_emoji) > 16 then
    raise exception 'INVALID_EMOJI';
  end if;

  insert into public.direct_message_reactions (message_id, conversation_id, user_id, emoji)
  values (p_message, v_conv, auth.uid(), p_emoji)
  on conflict (message_id, user_id)
  do update set emoji = excluded.emoji, created_at = now();
end;
$$;

create or replace function public.react_group_message(p_message uuid, p_emoji text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_grp uuid;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('group_react', coalesce(auth.uid()::text, private.client_ip()), 120, interval '10 minutes');

  select group_id into v_grp
    from public.group_messages
   where id = p_message
     and deleted_at is null
     and public.is_group_member(group_messages.group_id, auth.uid());

  if v_grp is null then
    raise exception 'NOT_ALLOWED';
  end if;

  p_emoji := btrim(coalesce(p_emoji, ''));
  if p_emoji = '' then
    delete from public.group_message_reactions
     where message_id = p_message and user_id = auth.uid();
    return;
  end if;
  if char_length(p_emoji) > 16 then
    raise exception 'INVALID_EMOJI';
  end if;

  insert into public.group_message_reactions (message_id, group_id, user_id, emoji)
  values (p_message, v_grp, auth.uid(), p_emoji)
  on conflict (message_id, user_id)
  do update set emoji = excluded.emoji, created_at = now();
end;
$$;

-- ----------------------------------------------------------------------------
-- Shape updates: is_builtin surfaces to the client.
-- ----------------------------------------------------------------------------
-- private.notify whitelist gains 'group_added' (kind was introduced with
-- builtin communities; helper rejects unknown kinds by design).
create or replace function private.notify(p_user uuid, p_kind text, p_payload jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_kind not in ('new_message', 'talk_request', 'talk_accepted',
                    'inactivity_warning', 'group_added') then
    raise exception 'NOTIFICATION_KIND_FORBIDDEN';
  end if;
  insert into public.notifications (user_id, kind, payload)
  values (p_user, p_kind, p_payload);
end;
$$;

-- Return-shape change (is_builtin added) — must drop before recreate.
drop function if exists public.list_my_groups();

create or replace function public.list_my_groups()
returns table (
  group_id        uuid,
  group_name      text,
  member_count    bigint,
  last_message    text,
  last_message_at timestamptz,
  last_sender_id  uuid,
  unread_count    bigint,
  is_builtin      boolean
) as $$
begin
  return query
  select
    g.id as group_id,
    g.name as group_name,
    (select count(*) from public.group_members gm where gm.group_id = g.id) as member_count,
    gm_inner.content as last_message,
    g.updated_at as last_message_at,
    gm_inner.sender_id as last_sender_id,
    coalesce((
      select count(*) from public.group_messages msg
      where msg.group_id = g.id
        and msg.sender_id != auth.uid()
        and msg.deleted_at is null
        and msg.created_at > coalesce(gm_self.last_read_at, gm_self.joined_at)
    ), 0) as unread_count,
    g.is_builtin
  from public.groups g
  join public.group_members gm_self on gm_self.group_id = g.id and gm_self.user_id = auth.uid()
  left join lateral (
    select msg.content, msg.sender_id, msg.created_at
    from public.group_messages msg
    where msg.group_id = g.id
    order by msg.created_at desc
    limit 1
  ) gm_inner on true
  order by g.updated_at desc;
end;
$$ language plpgsql security definer;

create or replace function public.get_group_info(p_group_id uuid)
returns json as $$
declare
  v_result json;
begin
  -- Verify membership
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_MEMBER';
  end if;

  select json_build_object(
    'id', g.id,
    'name', g.name,
    'creator_id', g.creator_id,
    'created_at', g.created_at,
    'is_builtin', g.is_builtin,
    'members', (
      select json_agg(json_build_object(
        'user_id', gm.user_id,
        'role', gm.role,
        'joined_at', gm.joined_at,
        'animal', p.animal,
        'display_animal_id', p.display_animal_id
      ) order by gm.role = 'admin' desc, gm.joined_at asc)
      from public.group_members gm
      join public.profiles p on p.id = gm.user_id
      where gm.group_id = g.id
    )
  ) into v_result
  from public.groups g
  where g.id = p_group_id;

  return v_result;
end;
$$ language plpgsql security definer;

-- ----------------------------------------------------------------------------
-- Privileges — authenticated only, deny public/anon.
-- ----------------------------------------------------------------------------
revoke execute on function public.list_builtin_groups()              from public, anon;
revoke execute on function public.join_builtin_group(uuid)           from public, anon;
revoke execute on function public.leave_builtin_group(uuid)          from public, anon;
revoke execute on function public.add_group_members(uuid, uuid[])    from public, anon;
revoke execute on function public.remove_group_member(uuid, uuid)    from public, anon;
revoke execute on function public.admin_create_builtin_group(text)   from public, anon, authenticated;
revoke execute on function public.admin_kick_builtin_member(uuid, uuid)   from public, anon, authenticated;
revoke execute on function public.admin_dissolve_builtin_group(uuid)      from public, anon, authenticated;
revoke execute on function public.admin_delete_group_message(uuid)        from public, anon, authenticated;
revoke execute on function public.send_direct_message(uuid, text, uuid)   from public, anon;
revoke execute on function public.send_group_message(uuid, text, uuid)    from public, anon;
revoke execute on function public.react_direct_message(uuid, text)        from public, anon;
revoke execute on function public.react_group_message(uuid, text)         from public, anon;
revoke execute on function public.list_my_groups()                        from public, anon;
revoke execute on function public.get_group_info(uuid)                    from public, anon;

grant execute on function public.list_builtin_groups()               to authenticated;
grant execute on function public.join_builtin_group(uuid)            to authenticated;
grant execute on function public.leave_builtin_group(uuid)           to authenticated;
grant execute on function public.add_group_members(uuid, uuid[])     to authenticated;
grant execute on function public.remove_group_member(uuid, uuid)     to authenticated;
grant execute on function public.admin_create_builtin_group(text)    to authenticated;
grant execute on function public.admin_kick_builtin_member(uuid, uuid)   to authenticated;
grant execute on function public.admin_dissolve_builtin_group(uuid)      to authenticated;
grant execute on function public.admin_delete_group_message(uuid)        to authenticated;
grant execute on function public.send_direct_message(uuid, text, uuid)   to authenticated;
grant execute on function public.send_group_message(uuid, text, uuid)    to authenticated;
grant execute on function public.react_direct_message(uuid, text)        to authenticated;
grant execute on function public.react_group_message(uuid, text)         to authenticated;
grant execute on function public.list_my_groups()                        to authenticated;
grant execute on function public.get_group_info(uuid)                    to authenticated;
