-- ============================================================================
-- JUNGLECHAT — 0312_revoke_change_my_animal.sql
--
-- Animal changes are strictly ad-gated (begin_ad_change / complete_ad_change).
-- change_my_animal(text) is dead code kept for reference only; revoke its
-- EXECUTE grant so it can never be called by clients (free-change bypass).
-- ============================================================================

revoke execute on function public.change_my_animal(text) from public, anon, authenticated;
