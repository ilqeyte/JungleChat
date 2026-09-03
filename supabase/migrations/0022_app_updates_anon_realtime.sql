-- 0022: app_updates Realtime for logged-out sessions.
--
-- The update gate runs BEFORE login, so its Realtime subscription on
-- app_updates is made with the anon role. The 0021 policy granted SELECT to
-- authenticated only, which meant a logged-out app never received the
-- "a release went live" event until the user logged in or restarted.
--
-- Exposure is unchanged: the policy still allows reading exactly the active
-- row, which is the same row get_latest_update() already returns to anon.

drop policy if exists app_updates_read_active on public.app_updates;
create policy app_updates_read_active
  on public.app_updates for select to anon, authenticated
  using (is_active);

-- Legacy policy from the pre-0021 ad-hoc table: any authenticated user could
-- read EVERY row, including inactive/unpublished releases. The read path is
-- the active-row policy above; drop the broad one.
drop policy if exists app_updates_select_auth on public.app_updates;

