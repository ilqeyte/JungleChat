-- ============================================================================
-- JungleChat - 0305b_restore_auto_delete_timer.sql
--
-- Restores the disappearing-message timer feature. The original definition
-- lived in migration 0020, which was archived during cleanup and therefore
-- never applied to fresh installs. Migration 0307 (message_expiry) consumes
-- conversations.auto_delete_interval / groups.auto_delete_interval, so the
-- columns and the timer RPCs MUST exist before 0307 runs.
--
-- This is a clean re-creation (no legacy "Adam"/project-specific cruft):
--   1. auto_delete_interval on conversations + groups (per-thread timer)
--   2. default_auto_delete_interval on profiles (user default for new threads)
--   3. validate_auto_delete_interval() helper
--   4. set/get RPCs used by the client
--   5. cleanup_auto_delete_messages() manual sweeper (the scheduled sweeper
--      itself is installed by 0307 via pg_cron)
--
-- All client-callable RPCs are authenticated-only; helpers are internal.
-- ============================================================================

-- 1. Columns -----------------------------------------------------------------
alter table public.conversations
  add column if not exists auto_delete_interval interval;

comment on column public.conversations.auto_delete_interval is
  'Per-conversation auto-delete timer. NULL = off. '
  'Valid: 24 hours, 7 days, 1 month, 3 months, 6 months, 12 months.';

alter table public.groups
  add column if not exists auto_delete_interval interval;

comment on column public.groups.auto_delete_interval is
  'Per-group auto-delete timer. NULL = off. '
  'Valid: 24 hours, 7 days, 1 month, 3 months, 6 months, 12 months.';

alter table public.profiles
  add column if not exists default_auto_delete_interval interval;

comment on column public.profiles.default_auto_delete_interval is
  'User default auto-delete timer applied to new conversations/groups. NULL = off.';

-- 2. Validation helper (internal) --------------------------------------------
create or replace function public.validate_auto_delete_interval(p_interval interval)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_interval is null then
    return true;
  end if;
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
$$;

-- 3. Client RPCs --------------------------------------------------------------
create or replace function public.set_conversation_auto_delete(
  p_conversation_id uuid,
  p_interval        interval
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.conversations
     where id = p_conversation_id
       and (user_a = auth.uid() or user_b = auth.uid())
  ) then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  if not public.validate_auto_delete_interval(p_interval) then
    raise exception 'INVALID_AUTO_DELETE_INTERVAL';
  end if;

  update public.conversations
     set auto_delete_interval = p_interval
   where id = p_conversation_id;
end;
$$;

create or replace function public.set_group_auto_delete(
  p_group_id uuid,
  p_interval interval
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_ADMIN';
  end if;

  if not public.validate_auto_delete_interval(p_interval) then
    raise exception 'INVALID_AUTO_DELETE_INTERVAL';
  end if;

  update public.groups
     set auto_delete_interval = p_interval
   where id = p_group_id;
end;
$$;

create or replace function public.set_my_default_auto_delete(p_interval interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.validate_auto_delete_interval(p_interval) then
    raise exception 'INVALID_AUTO_DELETE_INTERVAL';
  end if;

  update public.profiles
     set default_auto_delete_interval = p_interval
   where id = auth.uid();
end;
$$;

create or replace function public.get_my_default_auto_delete()
returns interval
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_interval interval;
begin
  select default_auto_delete_interval into v_interval
    from public.profiles
   where id = auth.uid();
  return v_interval;
end;
$$;

create or replace function public.get_conversation_auto_delete(p_conversation_id uuid)
returns interval
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_interval interval;
begin
  select auto_delete_interval into v_interval
    from public.conversations
   where id = p_conversation_id
     and (user_a = auth.uid() or user_b = auth.uid());
  return v_interval;
end;
$$;

create or replace function public.get_group_auto_delete(p_group_id uuid)
returns interval
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_interval interval;
begin
  select auto_delete_interval into v_interval
    from public.groups
   where id = p_group_id
     and public.is_group_member(p_group_id, auth.uid());
  return v_interval;
end;
$$;

-- 4. Manual sweeper (supplement to the pg_cron job in 0307) -------------------
create or replace function public.cleanup_auto_delete_messages()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer := 0;
begin
  with d as (
    delete from public.direct_messages dm
     using public.conversations c
     where dm.conversation_id = c.id
       and c.auto_delete_interval is not null
       and dm.created_at < now() - c.auto_delete_interval
       and dm.deleted_at is null
     returning 1
  )
  select count(*) into v_deleted from d;

  with g as (
    delete from public.group_messages gm
     using public.groups gr
     where gm.group_id = gr.id
       and gr.auto_delete_interval is not null
       and gm.created_at < now() - gr.auto_delete_interval
       and gm.deleted_at is null
     returning 1
  )
  select v_deleted + count(*) into v_deleted from g;

  return v_deleted;
end;
$$;

-- 5. Privileges ---------------------------------------------------------------
revoke execute on function public.validate_auto_delete_interval(interval)        from public, anon;
revoke execute on function public.cleanup_auto_delete_messages()                  from public, anon;
revoke execute on function public.set_conversation_auto_delete(uuid, interval)    from public, anon;
revoke execute on function public.set_group_auto_delete(uuid, interval)           from public, anon;
revoke execute on function public.set_my_default_auto_delete(interval)            from public, anon;
revoke execute on function public.get_my_default_auto_delete()                    from public, anon;
revoke execute on function public.get_conversation_auto_delete(uuid)              from public, anon;
revoke execute on function public.get_group_auto_delete(uuid)                     from public, anon;

grant execute on function public.set_conversation_auto_delete(uuid, interval)    to authenticated;
grant execute on function public.set_group_auto_delete(uuid, interval)           to authenticated;
grant execute on function public.set_my_default_auto_delete(interval)            to authenticated;
grant execute on function public.get_my_default_auto_delete()                    to authenticated;
grant execute on function public.get_conversation_auto_delete(uuid)              to authenticated;
grant execute on function public.get_group_auto_delete(uuid)                     to authenticated;
