-- ─── Auto-Delete Timer Feature ────────────────────────────────────────────────
-- Migration 020: Add auto-delete timer settings for conversations and groups
-- Allows users to set message auto-delete timer: 24h, 7d, 1m, 3m, 6m, 12m, or off (default)

-- ── 1. Add auto_delete_timer to conversations ──────────────────────────────────
-- Values: NULL = off (default), or interval string like '24 hours', '7 days', '1 month', '3 months', '6 months', '12 months'
alter table public.conversations
add column if not exists auto_delete_interval interval;

comment on column public.conversations.auto_delete_interval is
'Auto-delete interval for messages in this conversation. NULL = off. Valid values: 24 hours, 7 days, 1 month, 3 months, 6 months, 12 months.';

-- ── 2. Add auto_delete_timer to groups ─────────────────────────────────────────
alter table public.groups
add column if not exists auto_delete_interval interval;

comment on column public.groups.auto_delete_interval is
'Auto-delete interval for messages in this group. NULL = off. Valid values: 24 hours, 7 days, 1 month, 3 months, 6 months, 12 months.';

-- ── 3. Add auto_delete_interval to profiles for default setting ───────────────
alter table public.profiles
add column if not exists default_auto_delete_interval interval;

comment on column public.profiles.default_auto_delete_interval is
'Default auto-delete interval for new conversations/groups. NULL = off.';

-- ── 4. Function to validate interval ───────────────────────────────────────────
create or replace function public.validate_auto_delete_interval(p_interval interval)
returns boolean as $$
begin
  if p_interval is null then
    return true;
  end if;
  -- Check if interval is one of the allowed values
  if p_interval not in (
    interval '24 hours',
    interval '7 days',
    interval '1 month',
    interval '3 months',
    interval '6 months',
    interval '12 months'
  ) then
    return false;
  end if;
  return true;
end;
$$ language plpgsql security definer;

-- ── 5. Function to clean up old messages based on auto_delete_interval ─────────
-- This function should be called periodically (e.g., via pg_cron or scheduled job)
create or replace function public.cleanup_auto_delete_messages()
returns integer as $$
declare
  v_deleted_count integer := 0;
  v_conv_record record;
  v_group_record record;
  v_cutoff timestamptz;
begin
  -- Clean up direct_messages in conversations with auto_delete_interval set
  for v_conv_record in
    select id, auto_delete_interval
    from public.conversations
    where auto_delete_interval is not null
  loop
    v_cutoff := now() - v_conv_record.auto_delete_interval;
    delete from public.direct_messages
    where conversation_id = v_conv_record.id
      and created_at < v_cutoff
      and deleted_at is null;
    get diagnostics v_deleted_count = row_count;
  end loop;

  -- Clean up group_messages in groups with auto_delete_interval set
  for v_group_record in
    select id, auto_delete_interval
    from public.groups
    where auto_delete_interval is not null
  loop
    v_cutoff := now() - v_group_record.auto_delete_interval;
    delete from public.group_messages
    where group_id = v_group_record.id
      and created_at < v_cutoff
      and deleted_at is null;
    get diagnostics v_deleted_count = v_deleted_count + row_count;
  end loop;

  -- Also clean up room messages if they have auto_delete_interval (future-proofing)
  -- Note: rooms table doesn't have auto_delete_interval yet, but we can add it later if needed

  return v_deleted_count;
end;
$$ language plpgsql security definer;

-- ── 6. RPC to set auto-delete interval for a conversation ──────────────────────
create or replace function public.set_conversation_auto_delete(
  p_conversation_id uuid,
  p_interval interval
)
returns void as $$
begin
  -- Verify user is part of the conversation
  if not exists (
    select 1 from public.conversations
    where id = p_conversation_id
    and (user_a = auth.uid() or user_b = auth.uid())
  ) then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  -- Validate interval
  if not public.validate_auto_delete_interval(p_interval) then
    raise exception 'INVALID_AUTO_DELETE_INTERVAL';
  end if;

  update public.conversations
  set auto_delete_interval = p_interval
  where id = p_conversation_id;
end;
$$ language plpgsql security definer;

-- ── 7. RPC to set auto-delete interval for a group ─────────────────────────────
create or replace function public.set_group_auto_delete(
  p_group_id uuid,
  p_interval interval
)
returns void as $$
begin
  -- Verify user is admin of the group
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_ADMIN';
  end if;

  -- Validate interval
  if not public.validate_auto_delete_interval(p_interval) then
    raise exception 'INVALID_AUTO_DELETE_INTERVAL';
  end if;

  update public.groups
  set auto_delete_interval = p_interval
  where id = p_group_id;
end;
$$ language plpgsql security definer;

-- ── 8. RPC to set default auto-delete interval for current user ────────────────
create or replace function public.set_my_default_auto_delete(
  p_interval interval
)
returns void as $$
begin
  if not public.validate_auto_delete_interval(p_interval) then
    raise exception 'INVALID_AUTO_DELETE_INTERVAL';
  end if;

  update public.profiles
  set default_auto_delete_interval = p_interval
  where id = auth.uid();
end;
$$ language plpgsql security definer;

-- ── 9. RPC to get current user's default auto-delete setting ───────────────────
create or replace function public.get_my_default_auto_delete()
returns interval as $$
declare
  v_interval interval;
begin
  select default_auto_delete_interval into v_interval
  from public.profiles
  where id = auth.uid();

  return v_interval;
end;
$$ language plpgsql security definer;

-- ── 10. RPC to get conversation's auto-delete setting ──────────────────────────
create or replace function public.get_conversation_auto_delete(p_conversation_id uuid)
returns interval as $$
declare
  v_interval interval;
begin
  select auto_delete_interval into v_interval
  from public.conversations
  where id = p_conversation_id
  and (user_a = auth.uid() or user_b = auth.uid());

  if v_interval is null then
    return null;
  end if;

  return v_interval;
end;
$$ language plpgsql security definer;

-- ── 11. RPC to get group's auto-delete setting ─────────────────────────────────
create or replace function public.get_group_auto_delete(p_group_id uuid)
returns interval as $$
declare
  v_interval interval;
begin
  select auto_delete_interval into v_interval
  from public.groups
  where id = p_group_id
  and public.is_group_member(p_group_id, auth.uid());

  if v_interval is null then
    return null;
  end if;

  return v_interval;
end;
$$ language plpgsql security definer;

-- ── 12. Grant execute on new functions ─────────────────────────────────────────
-- (Security definer functions are executable by authenticated users by default)