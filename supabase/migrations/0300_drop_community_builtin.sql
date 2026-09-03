-- ============================================================================
-- 0300 — Drop the built-in community group entirely.
--
-- Phase 1, item #4. The built-in "Community" group (seeded in 0038) and every
-- builtin-specific RPC are removed. Groups become private-only: admin-created,
-- invitation-based, auto-dissolving when empty or when the creator leaves.
--
-- Runs AFTER 0038 and 0039 (lexical order), so it supersedes the private.notify
-- whitelist those migrations installed. Append-only: do not edit 0038/0039.
--
-- Re-runnable: every DROP uses `if exists`, and the recreated functions are
-- idempotent via `create or replace`.
-- ============================================================================

-- 1. Delete the seeded Community group. Cascades to group_members,
--    group_messages and reactions via existing FKs. No other group is builtin.
delete from public.groups where is_builtin;

-- 2. Drop the builtin-specific RPCs (no longer callable; old clients that call
--    them will receive a generic error via SafeErrors, never a crash).
drop function if exists public.list_builtin_groups();
drop function if exists public.join_builtin_group(uuid);
drop function if exists public.leave_builtin_group(uuid);
drop function if exists public.admin_create_builtin_group(text);
drop function if exists public.admin_kick_builtin_member(uuid, uuid);
drop function if exists public.admin_dissolve_builtin_group(uuid);
drop function if exists public.admin_delete_group_message(uuid);

-- 3a. Rewrite add_group_members as private-group-only (admin adds via the
--     existing-conversation invitation flow; no open "any member adds" path).
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
    v_cap int := 50;
begin
    if not exists (select 1 from public.groups where id = p_group_id) then
        raise exception 'GROUP_NOT_FOUND';
    end if;

    -- Private groups: admin only.
    if not public.is_group_admin(p_group_id, v_inviter_id) then
        raise exception 'NOT_GROUP_ADMIN';
    end if;

    -- Member cap (50 private).
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

        -- PRIVATE GROUPS: invitation flow. Requires an existing conversation
        -- between inviter and invitee.
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
    end loop;

    return v_added;
end;
$$ language plpgsql security definer;

-- 3b. Rewrite remove_group_member without the builtin "never dissolve" exemption.
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

  -- If creator left, dissolve group.
  if p_user_id = auth.uid() and exists (
    select 1 from public.groups where id = p_group_id and creator_id = auth.uid()
  ) then
    delete from public.groups where id = p_group_id;
    return true; -- group dissolved
  end if;

  -- If group has < 2 members, dissolve.
  if (select count(*) from public.group_members where group_id = p_group_id) < 2 then
    delete from public.groups where id = p_group_id;
    return true;
  end if;

  return false;
end;
$$ language plpgsql security definer;

-- 4. Drop the column now that no function or client depends on it.
alter table public.groups drop column if exists is_builtin;

-- 5. private.notify: remove 'group_added' from the allowed-kind whitelist.
create or replace function private.notify(p_user uuid, p_kind text, p_payload jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_kind not in ('new_message', 'talk_request', 'talk_accepted',
                    'inactivity_warning') then
    raise exception 'NOTIFICATION_KIND_FORBIDDEN';
  end if;
  insert into public.notifications (user_id, kind, payload)
  values (p_user, p_kind, p_payload);
end;
$$;

-- 6. Update list_my_groups to stop returning is_builtin.
drop function if exists public.list_my_groups();
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
    coalesce((
      select count(*) from public.group_messages msg
      where msg.group_id = g.id
        and msg.sender_id != auth.uid()
        and msg.deleted_at is null
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

-- 7. Update get_group_info to stop returning is_builtin.
create or replace function public.get_group_info(p_group_id uuid)
returns json as $$
declare
  v_result json;
begin
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

-- 8. Purge orphaned notifications of the now-removed kind.
delete from public.notifications where kind = 'group_added';

-- ----------------------------------------------------------------------------
-- Privileges — re-grant the surviving group functions (recreate drops perms).
-- ----------------------------------------------------------------------------
revoke execute on function public.add_group_members(uuid, uuid[])     from public, anon;
revoke execute on function public.remove_group_member(uuid, uuid)     from public, anon;
revoke execute on function public.list_my_groups()                    from public, anon;
revoke execute on function public.get_group_info(uuid)                from public, anon;

grant execute on function public.add_group_members(uuid, uuid[])      to authenticated;
grant execute on function public.remove_group_member(uuid, uuid)      to authenticated;
grant execute on function public.list_my_groups()                     to authenticated;
grant execute on function public.get_group_info(uuid)                 to authenticated;
