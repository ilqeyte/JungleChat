-- ============================================================================
-- JUNGLECHAT — 0026_admin_rpc_hardening.sql
--
-- Hardens two prod-only admin functions that were deployed WITHOUT the
-- standard gates. Signatures are preserved exactly (the Flutter admin
-- dashboard depends on them), so this is a security-only patch.
--
--   admin_list_users      -> was SECURITY DEFINER + PUBLIC execute + NO gate.
--                            Any authenticated user could enumerate every
--                            profile. Now requires an admin_roles row.
--   admin_suspend_user    -> only checked admin_roles existence but lacked
--                            set search_path = ''. Now sets empty search_path
--                            and audits through private.admin_audit().
--
-- NOTE ON aal2: private.is_admin() additionally requires an MFA-elevated
-- (aal2) session. The current Flutter client performs NO MFA challenge yet
-- (password-only admin sign-in), so these two gate on admin_roles membership
-- instead of is_admin() to avoid breaking the dashboard. Once MFA is added to
-- the client, move them to private.is_admin(). See docs/AUDIT-2026-08-30.md.
-- ============================================================================

create or replace function public.admin_list_users()
returns table (
  user_id              uuid,
  animal               text,
  animal_number        integer,
  display_animal_id    text,
  status               text,
  open_to_talk         boolean,
  last_active_at       timestamp with time zone,
  created_at           timestamp with time zone,
  deleted_at           timestamp with time zone,
  delete_undo_deadline timestamp with time zone
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  return query
    select
      p.id,
      ai.animal,
      ai.number,
      p.display_animal_id,
      p.status::text,
      p.open_to_talk,
      p.last_active_at,
      p.created_at,
      p.deleted_at,
      p.delete_undo_deadline
    from public.profiles p
    left join public.animal_id ai on ai.user_id = p.id
    order by p.created_at desc;
end;
$$;

create or replace function public.admin_suspend_user(
  p_user_id uuid,
  p_status text,
  p_reason text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  update public.profiles
     set status = p_status::public.account_status
   where id = p_user_id;

  perform private.admin_audit('user.status_changed',
    jsonb_build_object('target', p_user_id, 'status', p_status,
                       'reason', p_reason));
end;
$$;

-- ============================================================================
-- PRIVILEGES — authenticated only (never anon); is_admin() is the real gate.
-- ============================================================================
revoke execute on function public.admin_list_users()         from public, anon, authenticated;
revoke execute on function public.admin_suspend_user(uuid,text,text) from public, anon, authenticated;

grant execute on function public.admin_list_users()          to authenticated;
grant execute on function public.admin_suspend_user(uuid,text,text) to authenticated;