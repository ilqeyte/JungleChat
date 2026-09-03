-- ============================================================================
-- JUNGLECHAT — 0043_submit_deletion_appeal.sql
--
-- FIXES A LIVE BUG: app/lib/features/admin/account_deleted_dialog.dart calls
-- rpc('submit_deletion_appeal', params: {'p_body': ...}) but that function
-- existed in NO migration. Every "Contact Admin" press threw
--   "Could not find the function public.submit_deletion_appeal(...)"
-- and the user saw the generic "Something went wrong. Please try again."
-- The one affordance a soft-deleted user has to reach a human was 100% dead.
--
-- Requires 0042 (the 'deletion_appeal' enum value) to have COMMITTED first.
--
-- DESIGN NOTES
-- ---------------------------------------------------------------------------
-- 1. This RPC deliberately does NOT call private.ensure_active_account().
--    admin_delete_user (0035) soft-deletes by setting deleted_at AND
--    status = 'banned', and ensure_active_account raises ACCOUNT_RESTRICTED
--    for 'banned' — i.e. it rejects exactly the people this function exists
--    to serve. The guard would make the RPC useless by construction, so we
--    require only that a profile row exists for the authenticated caller.
--
--    Note the caller still authenticates: admin_delete_user also clears
--    auth.sessions / auth.refresh_tokens, but an already-issued access token
--    stays cryptographically valid until it expires (~1h). That is precisely
--    the window in which kick_out_listener shows this dialog, so an appeal
--    is submittable exactly while the user is staring at it.
--
-- 2. Rate limiting is server-side (charter rule 6): 3 appeals per 24h, keyed
--    on the caller's uuid so it cannot be evaded by rotating sessions or IPs.
--
-- 3. The body is length-checked here so the caller gets our clean
--    INVALID_REPORT_BODY instead of the reports_body_chk constraint leaking
--    a schema detail in a Postgres error string.
--
-- 4. target_user_id is set to the caller, because admin_list_reports left
--    joins profiles on target_user_id to surface `reported_animal`. That is
--    what lets Adam see WHO is appealing. Admin-only surface; no exposure to
--    other users (charter rule 8 concerns notifications, not reports).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PRODUCTION DRIFT (verified against the live DB 2026-09-01): an ad-hoc copy
-- of this function was created directly in the SQL editor and is NOT part of
-- migration history. It RETURNS void and has no search_path pin, no rate
-- limit and no body validation. CREATE OR REPLACE cannot change a function's
-- return type, so the drifted copy is dropped first and replaced with the
-- hardened definition below. Nothing else depends on it.
-- ----------------------------------------------------------------------------
drop function if exists public.submit_deletion_appeal(text);

create or replace function public.submit_deletion_appeal(p_body text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me     uuid := auth.uid();
  v_status public.account_status;
  v_ref    text;
begin
  if v_me is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  select status into v_status from public.profiles where id = v_me;
  if v_status is null then
    raise exception 'ACCOUNT_NOT_FOUND';
  end if;

  perform private.rate_limit('deletion_appeal', v_me::text, 3, interval '24 hours');

  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 2000 then
    raise exception 'INVALID_REPORT_BODY';
  end if;

  insert into public.reports (reporter_id, type, target_user_id, body)
  values (v_me, 'deletion_appeal'::public.report_type, v_me, p_body)
  returning human_ref into v_ref;

  return v_ref;
end;
$$;

-- ============================================================================
-- PRIVILEGES — deny by default, then grant to authenticated only.
-- ============================================================================
revoke execute on function public.submit_deletion_appeal(text) from public, anon;
grant  execute on function public.submit_deletion_appeal(text) to authenticated;
