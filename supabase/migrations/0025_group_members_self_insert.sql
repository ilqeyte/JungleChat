-- ============================================================================
-- JUNGLECHAT — 0025_group_members_self_insert.sql
--
-- Hardens the group_members INSERT policy. The old policy only required that
-- the CALLER is already a member of the group, but never required that the
-- inserted row belongs to the caller. That let any member insert a row with an
-- arbitrary user_id, force-adding that user to a group and bypassing the block
-- checks in add_group_members(). Membership now inserts only for oneself.
--
-- SAFETY: purely additive — softens nothing, hardens a security check only.
-- ============================================================================

drop policy if exists group_members_insert_auth on public.group_members;

create policy "group_members_insert_auth" on public.group_members
  for insert with check (
    user_id = auth.uid()
    and public.is_group_member(group_id, auth.uid())
  );