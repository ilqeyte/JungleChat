-- ============================================================================
-- JUNGLECHAT - 0036_animal_profile.sql
--
-- Public profile screen: fetch ONE animal's public identity card by user id.
-- Backs /profile/:id — opened from private-chat titles, group member rows,
-- group message sender names and chats-list avatars.
--
-- PRIVACY (charter): returns only the public identity card already exposed
-- by discovery/search — animal kind, display Animal ID, open_to_talk, bio,
-- is_online (is_user_online already respects visibility_online). User ids
-- are only visible to people who already share a conversation or group with
-- the animal. Deleted / suspended profiles return NO row (client shows
-- "gone"), so the endpoint can never leak their card.
-- ============================================================================

create or replace function public.get_animal_profile(p_user uuid)
returns table (
  id uuid,
  animal text,
  display_animal_id text,
  open_to_talk boolean,
  bio text,
  is_online boolean
)
language sql stable security definer set search_path = ''
as $$
  select p.id, p.animal, p.display_animal_id, p.open_to_talk, p.bio,
         public.is_user_online(p.id)
    from public.profiles p
   where p.id = p_user
     and p.deleted_at is null
     and p.status = 'active';
$$;

revoke execute on function public.get_animal_profile(uuid) from public, anon;
grant execute on function public.get_animal_profile(uuid) to authenticated;
