-- ─── Group Chat System ───────────────────────────────────────────────────────
-- Migration 0017: groups, group_members, group_messages

-- ── Groups ───────────────────────────────────────────────────────────────────

create table public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 50),
  creator_id  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.groups is 'Chat groups created by users.';

-- ── Group Members ─────────────────────────────────────────────────────────────

create type public.group_role as enum ('admin', 'member');

create table public.group_members (
  group_id   uuid not null references public.groups(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       public.group_role not null default 'member',
  joined_at  timestamptz not null default now(),
  primary key (group_id, user_id)
);

comment on table public.group_members is 'Membership join table for groups.';

-- ── Group Messages ────────────────────────────────────────────────────────────

create table public.group_messages (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups(id) on delete cascade,
  sender_id   uuid not null references auth.users(id) on delete cascade,
  content     text not null check (char_length(content) between 1 and 1000),
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  deleted_by  uuid references auth.users(id)
);

comment on table public.group_messages is 'Messages within a group chat.';

-- ── Indexes ───────────────────────────────────────────────────────────────────

create index idx_group_members_user     on public.group_members(user_id);
create index idx_group_messages_group   on public.group_messages(group_id, created_at desc);
create index idx_group_messages_sender  on public.group_messages(sender_id);

-- ── Groups: updated_at trigger ────────────────────────────────────────────────

create or replace function public.set_groups_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_groups_updated_at
  before update on public.groups
  for each row execute function public.set_groups_updated_at();

-- ── Helper: check group membership ────────────────────────────────────────────

create or replace function public.is_group_member(p_group_id uuid, p_user_id uuid)
returns boolean as $$
begin
  return exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = p_user_id
  );
end;
$$ language plpgsql security definer;

-- ── Helper: check group admin ─────────────────────────────────────────────────

create or replace function public.is_group_admin(p_group_id uuid, p_user_id uuid)
returns boolean as $$
begin
  return exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = p_user_id and role = 'admin'
  );
end;
$$ language plpgsql security definer;

-- ── RPC: create_group ────────────────────────────────────────────────────────
-- Creates a group and adds initial members.
-- p_member_ids: array of user UUIDs to add (creator is auto-added as admin)

create or replace function public.create_group(
  p_name       text,
  p_member_ids uuid[]
)
returns uuid as $$
declare
  v_group_id uuid;
  v_member   uuid;
begin
  -- Validate name
  if char_length(trim(p_name)) < 1 or char_length(p_name) > 50 then
    raise exception 'INVALID_GROUP_NAME';
  end if;

  -- Validate member count (2-50 including creator)
  if array_length(p_member_ids, 1) is null or array_length(p_member_ids, 1) < 1 then
    raise exception 'GROUP_NEEDS_AT_LEAST_ONE_MEMBER';
  end if;

  if array_length(p_member_ids, 1) > 49 then
    raise exception 'GROUP_TOO_MANY_MEMBERS';
  end if;

  -- Rate limit: max 5 groups created per user per day
  perform private.rate_limit('create_group', auth.uid()::text, 5, interval '24 hours');

  -- Create group
  insert into public.groups (name, creator_id)
  values (trim(p_name), auth.uid())
  returning id into v_group_id;

  -- Add creator as admin
  insert into public.group_members (group_id, user_id, role)
  values (v_group_id, auth.uid(), 'admin');

  -- Add members
  foreach v_member in array p_member_ids loop
    -- Skip creator (already added)
    if v_member = auth.uid() then
      continue;
    end if;

    -- Verify member exists and is active
    if not exists (
      select 1 from public.profiles
      where id = v_member and status = 'active' and deleted_at is null
    ) then
      raise exception 'INVALID_MEMBER %', v_member;
    end if;

    -- Skip blocks: don't add if creator has blocked them or they've blocked creator
    if private.blocked_between(auth.uid(), v_member) then
      continue;
    end if;

    insert into public.group_members (group_id, user_id, role)
    values (v_group_id, v_member, 'member')
    on conflict do nothing;
  end loop;

  -- Ensure at least 2 members (creator + 1 other)
  if (select count(*) from public.group_members where group_id = v_group_id) < 2 then
    raise exception 'GROUP_NEEDS_AT_LEAST_ONE_MEMBER';
  end if;

  return v_group_id;
end;
$$ language plpgsql security definer;

-- ── RPC: list_my_groups ──────────────────────────────────────────────────────
-- Returns groups the current user belongs to, with last message preview.

create or replace function public.list_my_groups()
returns table (
  group_id        uuid,
  group_name      text,
  member_count    bigint,
  last_message    text,
  last_message_at timestamptz,
  last_sender_id  uuid,
  unread_count    bigint
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
    -- Unread: messages after user's last read (we use a simple approach: count messages not sent by user since group updated_at > user's joined_at)
    -- For MVP, we count messages since group was last accessed. We'll use a simpler approach:
    -- Count messages where created_at > (user's last visit or group_members.joined_at)
    coalesce((
      select count(*) from public.group_messages msg
      where msg.group_id = g.id
        and msg.sender_id != auth.uid()
        and msg.created_at > coalesce(gm_self.last_read_at, gm_self.joined_at)
    ), 0) as unread_count
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

-- ── RPC: send_group_message ──────────────────────────────────────────────────
-- Sends a message to a group. Validates membership.

create or replace function public.send_group_message(
  p_group_id uuid,
  p_content  text
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

  -- Insert message
  insert into public.group_messages (group_id, sender_id, content)
  values (p_group_id, auth.uid(), v_trimmed)
  returning id into v_msg_id;

  -- Update group timestamp
  update public.groups set updated_at = now() where id = p_group_id;

  return v_msg_id;
end;
$$ language plpgsql security definer;

-- ── RPC: list_group_messages ─────────────────────────────────────────────────
-- Loads messages for a group with pagination.

create or replace function public.list_group_messages(
  p_group_id uuid,
  p_before   timestamptz default null,
  p_limit    int default 50
)
returns table (
  id         uuid,
  sender_id  uuid,
  content    text,
  created_at timestamptz,
  is_mine    boolean
) as $$
begin
  -- Verify membership
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_MEMBER';
  end if;

  return query
  select
    msg.id,
    msg.sender_id,
    msg.content,
    msg.created_at,
    (msg.sender_id = auth.uid()) as is_mine
  from public.group_messages msg
  where msg.group_id = p_group_id
    and msg.deleted_at is null
    and (p_before is null or msg.created_at < p_before)
  order by msg.created_at desc
  limit least(p_limit, 200);
end;
$$ language plpgsql security definer;

-- ── RPC: add_group_members ───────────────────────────────────────────────────
-- Adds members to an existing group. Only admins can do this.

create or replace function public.add_group_members(
  p_group_id   uuid,
  p_member_ids uuid[]
)
returns int as $$
declare
  v_member uuid;
  v_added  int := 0;
begin
  -- Must be admin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_ADMIN';
  end if;

  -- Max 50 members per group
  if (select count(*) from public.group_members where group_id = p_group_id) + array_length(p_member_ids, 1) > 50 then
    raise exception 'GROUP_TOO_MANY_MEMBERS';
  end if;

  foreach v_member in array p_member_ids loop
    -- Skip if already member
    if public.is_group_member(p_group_id, v_member) then
      continue;
    end if;

    -- Verify member exists and is active
    if not exists (
      select 1 from public.profiles
      where id = v_member and status = 'active' and deleted_at is null
    ) then
      continue;
    end if;

    -- Skip blocks
    if private.blocked_between(auth.uid(), v_member) then
      continue;
    end if;

    insert into public.group_members (group_id, user_id, role)
    values (p_group_id, v_member, 'member')
    on conflict do nothing;

    v_added := v_added + 1;
  end loop;

  return v_added;
end;
$$ language plpgsql security definer;

-- ── RPC: remove_group_member ─────────────────────────────────────────────────
-- Removes a member from a group. Admins can remove anyone; members can remove themselves (leave).

create or replace function public.remove_group_member(
  p_group_id uuid,
  p_user_id  uuid
)
returns boolean as $$
begin
  -- Must be admin or removing self
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

  -- If creator left, dissolve group
  if p_user_id = auth.uid() and exists (
    select 1 from public.groups where id = p_group_id and creator_id = auth.uid()
  ) then
    delete from public.groups where id = p_group_id;
    return true; -- group dissolved
  end if;

  -- If group has < 2 members, dissolve
  if (select count(*) from public.group_members where group_id = p_group_id) < 2 then
    delete from public.groups where id = p_group_id;
    return true; -- group dissolved
  end if;

  return false; -- group still exists
end;
$$ language plpgsql security definer;

-- ── RPC: get_group_info ──────────────────────────────────────────────────────
-- Returns group details + members list.

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

-- ── RPC: update_group_name ───────────────────────────────────────────────────
-- Updates group name. Only admins can do this.

create or replace function public.update_group_name(
  p_group_id uuid,
  p_new_name text
)
returns void as $$
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_ADMIN';
  end if;

  if char_length(trim(p_new_name)) < 1 or char_length(p_new_name) > 50 then
    raise exception 'INVALID_GROUP_NAME';
  end if;

  update public.groups set name = trim(p_new_name) where id = p_group_id;
end;
$$ language plpgsql security definer;

-- ── RPC: mark_group_read ─────────────────────────────────────────────────────
-- Marks a group as read (resets unread count tracking).

-- Add last_read_at to group_members
alter table public.group_members
  add column if not exists last_read_at timestamptz default now();

create or replace function public.mark_group_read(p_group_id uuid)
returns void as $$
begin
  update public.group_members
  set last_read_at = now()
  where group_id = p_group_id and user_id = auth.uid();
end;
$$ language plpgsql security definer;

-- ── RLS Policies ─────────────────────────────────────────────────────────────

alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_messages enable row level security;

alter table public.groups force row level security;
alter table public.group_members force row level security;
alter table public.group_messages force row level security;

-- Groups: members can read
create policy "groups_select_member" on public.groups
  for select using (public.is_group_member(id, auth.uid()));

-- Groups: authenticated can insert (create_group RPC handles validation)
create policy "groups_insert_auth" on public.groups
  for insert with check (creator_id = auth.uid());

-- Groups: admins can update
create policy "groups_update_admin" on public.groups
  for update using (public.is_group_admin(id, auth.uid()));

-- Groups: admins can delete (dissolve)
create policy "groups_delete_admin" on public.groups
  for delete using (public.is_group_admin(id, auth.uid()) or creator_id = auth.uid());

-- Group Members: members can read
create policy "group_members_select_member" on public.group_members
  for select using (public.is_group_member(group_id, auth.uid()));

-- Group Members: authenticated can insert (RPC handles validation)
create policy "group_members_insert_auth" on public.group_members
  for insert with check (public.is_group_member(group_id, auth.uid()));

-- Group Members: admins or self can update
create policy "group_members_update_admin" on public.group_members
  for update using (public.is_group_admin(group_id, auth.uid()) or user_id = auth.uid());

-- Group Members: admins or self can delete
create policy "group_members_delete_admin" on public.group_members
  for delete using (public.is_group_admin(group_id, auth.uid()) or user_id = auth.uid());

-- Group Messages: members can read
create policy "group_messages_select_member" on public.group_messages
  for select using (public.is_group_member(group_id, auth.uid()));

-- Group Messages: members can insert (RPC handles validation)
create policy "group_messages_insert_member" on public.group_messages
  for insert with check (public.is_group_member(group_id, auth.uid()) and sender_id = auth.uid());

-- ── Realtime Publication ─────────────────────────────────────────────────────

-- Add group_messages to the supabase_realtime publication
alter publication supabase_realtime add table public.group_messages;

