-- ─── Group Invitation System ─────────────────────────────────────────────────────
-- Migration 019: change group creation and member addition to invitation-based,
-- add notification kind 'group_invitation', and RPCs to accept/reject invitations.

-- ── 1. Modify create_group RPC: only create group, add creator as admin, do not add members ────
drop function if exists public.create_group(text, uuid[]);
create or replace function public.create_group(
    p_name       text,
    p_member_ids uuid[]  -- kept for compatibility but ignored
)
returns uuid as $$
declare
    v_group_id uuid;
begin
    -- Validate name
    if char_length(trim(p_name)) < 1 or char_length(p_name) > 50 then
        raise exception 'INVALID_GROUP_NAME';
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

    return v_group_id;
end;
$$ language plpgsql security definer;

-- ── 2. Modify add_group_members RPC: send invitations instead of directly adding members ────
drop function if exists public.add_group_members(uuid, uuid[]);
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
begin
    -- Must be admin of the group
    if not public.is_group_admin(p_group_id, v_inviter_id) then
        raise exception 'NOT_GROUP_ADMIN';
    end if;

    -- Get group name for notification payload
    select name into v_group_name from public.groups where id = p_group_id;
    if v_group_name is null then
        raise exception 'GROUP_NOT_FOUND';
    end if;

    -- Get inviter's display animal id for notification
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

        -- Verify invitee has open_to_talk = true
        if not (select open_to_talk from public.profiles where id = v_member) then
            continue;
        end if;

        -- Verify that inviter and invitee have accepted each other to talk:
        -- i.e., there exists a conversation between them.
        if not exists (
            select 1 from public.conversations
            where (user_a = v_inviter_id and user_b = v_member)
               or (user_a = v_member and user_b = v_inviter_id)
        ) then
            continue;
        end if;

        -- Skip blocks: don't invite if inviter has blocked invitee or vice versa
        if private.blocked_between(v_inviter_id, v_member) then
            continue;
        end if;

        -- Insert notification for group invitation
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

-- ── 3. RPC to accept a group invitation ────────────────────────────────────────
drop function if exists public.accept_group_invitation(uuid);
create or replace function public.accept_group_invitation(p_notification_id uuid)
returns void as $$
declare
    v_notification      jsonb;
    v_group_id          uuid;
    v_group_name        text;
    v_inviter_id        uuid;
    v_current_user_id   uuid := auth.uid();
begin
    -- Fetch notification and verify kind and that it belongs to current user
    select kind, payload into v_notification
    from public.notifications
    where id = p_notification_id and user_id = v_current_user_id;

    if v_notification is null then
        raise exception 'NOTIFICATION_NOT_FOUND';
    end if;

    if (v_notification->>'kind') <> 'group_invitation' then
        raise exception 'INVALID_NOTIFICATION_KIND';
    end if;

    -- Extract payload
    v_group_id := (v_notification->>'group_id')::uuid;
    v_group_name := v_notification->>'group_name';
    v_inviter_id := (v_notification->>'inviter_id')::uuid;

    -- Verify group exists
    if not exists (select 1 from public.groups where id = v_group_id) then
        raise exception 'GROUP_NOT_FOUND';
    end if;

    -- Verify inviter is still admin (optional, but we can allow acceptance anyway)
    -- Insert as member
    insert into public.group_members (group_id, user_id, role)
    values (v_group_id, v_current_user_id, 'member')
    on conflict do nothing;

    -- Delete the notification
    delete from public.notifications where id = p_notification_id;

    -- Optionally, send a notification to the inviter that their invitation was accepted?
    /* We'll skip for now to keep it simple. */
end;
$$ language plpgsql security definer;

-- ── 4. RPC to reject/ignore a group invitation ─────────────────────────────────
drop function if exists public.reject_group_invitation(uuid);
create or replace function public.reject_group_invitation(p_notification_id uuid)
returns void as $$
declare
    v_current_user_id uuid := auth.uid();
begin
    delete from public.notifications
    where id = p_notification_id and user_id = v_current_user_id and
          (payload->>'kind') = 'group_invitation';
end;
$$ language plpgsql security definer;

-- ── 5. Add notification kind 'group_invitation' to the notifications table? ────
-- No schema change needed; we just use the kind text.

-- ── 6. Grant execute on new functions to authenticated users (via security definer, already set) ────
-- No extra grants needed.