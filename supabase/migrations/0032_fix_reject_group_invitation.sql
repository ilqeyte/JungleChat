-- ============================================================================
-- JUNGLECHAT — 0032_fix_reject_group_invitation.sql
--
-- Regression fix for 0031: the rewritten reject_group_invitation filtered
-- rows with (payload->>'kind') = 'group_invitation', but kind is a COLUMN
-- of notifications, not a payload key — so the DELETE matched nothing and
-- IGNORE silently did nothing. Filter on the kind column, as 019 did.
-- ============================================================================

create or replace function public.reject_group_invitation(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.notifications
   where id = p_notification_id
     and user_id = auth.uid()
     and kind = 'group_invitation';
end;
$$;

revoke all on function public.reject_group_invitation(uuid) from public, anon;
grant execute on function public.reject_group_invitation(uuid) to authenticated;
