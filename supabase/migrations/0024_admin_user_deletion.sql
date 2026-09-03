-- ============================================================================
-- JUNGLECHAT — 0024_admin_user_deletion.sql
--
-- Backfills the user-deletion RPCs into the repo and normalizes prod.
--
-- CONTEXT
--   The client has always called admin_delete_user / admin_undo_delete_user,
--   but no migration ever defined them — they existed only in prod, invisible
--   and unverifiable. This migration creates them with the standard pattern.
--   CREATE OR REPLACE means applying it to prod REPLACES the unknown prod
--   versions with these audited, gated definitions.
--
-- WHY NO HARD DELETE HERE
--   Removing an auth identity (auth.users) is not possible from SQL on
--   hosted Supabase — auth.users is owned by supabase_auth_admin, so a
--   SECURITY DEFINER function gets "permission denied for schema auth".
--   Permanent deletion is done by the admin-hard-delete-user Edge Function,
--   which uses the Auth Admin API with the service-role key.
--
-- SEMANTICS
--   * Soft delete: profile.deleted_at + 7-day undo deadline, status 'banned'
--     (satisfies profiles_deleted_chk), sessions killed, animal ID released
--     by the 0018 trigger. Reversible until the deadline.
--   * Undo: only inside the deadline.
--   * Neither can target an admin or the caller themself.
-- ============================================================================

-- The undo deadline column may not exist in older deployments.
alter table public.profiles
  add column if not exists delete_undo_deadline timestamptz;

-- ----------------------------------------------------------------------------
-- admin_delete_user — soft delete with a 7-day undo window.
-- Param is p_user_id to match the existing client call exactly.
-- ----------------------------------------------------------------------------
create or replace function public.admin_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.profiles%rowtype;
begin
  if not private.is_admin() then
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
  delete from auth.sessions       where user_id = p_user_id;
  delete from auth.refresh_tokens where user_id = p_user_id;

  perform private.admin_audit('user.soft_deleted',
    jsonb_build_object('target', p_user_id,
                       'undo_deadline', now() + interval '7 days'));
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_undo_delete_user — restore a soft-deleted user inside the window.
-- ----------------------------------------------------------------------------
create or replace function public.admin_undo_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.profiles%rowtype;
begin
  if not private.is_admin() then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_user_id;
  if v_target.id is null or v_target.deleted_at is null then
    raise exception 'TARGET_NOT_DELETED';
  end if;
  if v_target.delete_undo_deadline is not null
     and v_target.delete_undo_deadline < now() then
    raise exception 'UNDO_WINDOW_EXPIRED';
  end if;

  update public.profiles
     set deleted_at = null,
         delete_undo_deadline = null,
         status = 'active'
   where id = p_user_id;

  perform private.admin_audit('user.soft_delete_undone',
    jsonb_build_object('target', p_user_id));
end;
$$;

-- ============================================================================
-- PRIVILEGES — authenticated only, never anon. is_admin() is the real gate.
-- ============================================================================
revoke execute on function public.admin_delete_user(uuid)      from public, anon, authenticated;
revoke execute on function public.admin_undo_delete_user(uuid) from public, anon, authenticated;

grant execute on function public.admin_delete_user(uuid)       to authenticated;
grant execute on function public.admin_undo_delete_user(uuid)  to authenticated;
