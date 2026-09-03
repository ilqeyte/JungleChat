-- ============================================================================
-- 0301 — Drop the server-side sound preference (item #5).
--
-- Sounds are removed client-side (audioplayers + WAV assets gone). The
-- server column is dropped here. Per the plan, the client that no longer
-- reads/wends this column ships in the same batch; old installed clients that
-- still pass sounds_enabled will receive a generic "function not found" error
-- (handled by SafeErrors), never a crash.
--
-- Runs after 0028 (authoritative definition of get_my_profile / update_my_settings).
-- Re-runnable: idempotent drops and recreate.
-- ============================================================================

-- 1. Drop the column. Remaining columns (haptics_enabled etc.) are untouched.
alter table public.profiles drop column if exists sounds_enabled;

-- 2. get_my_profile — stop returning sounds_enabled.
drop function if exists public.get_my_profile();
create or replace function public.get_my_profile()
returns table (
  id uuid, display_animal_id text, animal text, open_to_talk boolean,
  random_talk_enabled boolean, typing_indicator_enabled boolean,
  in_app_alerts boolean, haptics_enabled boolean,
  status public.account_status, visibility_online boolean, bio text,
  is_online boolean, days_until_delete int, created_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select
    p.id, p.display_animal_id, p.animal, p.open_to_talk,
    p.random_talk_enabled, p.typing_indicator_enabled,
    p.in_app_alerts, p.haptics_enabled, p.status,
    p.visibility_online, p.bio,
    public.is_user_online(p.id),
    greatest(0, 90 - extract(day from now() - p.last_active_at)::int),
    p.created_at
  from public.profiles p
  where p.id = auth.uid() and p.deleted_at is null;
$$;

-- 3. update_my_settings — drop the p_sounds_enabled parameter and assignment.
drop function if exists public.update_my_settings(
  boolean, boolean, boolean, boolean, boolean, boolean, boolean, text);
create or replace function public.update_my_settings(
  p_open_to_talk boolean default null, p_random_talk boolean default null,
  p_typing_indicator boolean default null, p_in_app_alerts boolean default null,
  p_haptics_enabled boolean default null,
  p_visibility_online boolean default null, p_bio text default null
)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_bio text;
begin
  perform private.ensure_active_account();
  perform private.client_rate_limit('update_settings', 30, interval '10 minutes');
  v_bio := nullif(btrim(coalesce(p_bio, '')), '');
  if v_bio is not null and char_length(v_bio) > 160 then
    raise exception 'INVALID_BIO' using errcode = '22021';
  end if;
  update public.profiles
     set open_to_talk = coalesce(p_open_to_talk, open_to_talk),
         random_talk_enabled = coalesce(p_random_talk, random_talk_enabled),
         typing_indicator_enabled = coalesce(p_typing_indicator, typing_indicator_enabled),
         in_app_alerts = coalesce(p_in_app_alerts, in_app_alerts),
         haptics_enabled = coalesce(p_haptics_enabled, haptics_enabled),
         visibility_online = coalesce(p_visibility_online, visibility_online),
         bio = coalesce(v_bio, bio)
   where id = auth.uid();
  perform private.touch_activity();
end;
$$;

-- Re-grant (recreate drops perms).
revoke execute on function public.get_my_profile()            from public, anon;
revoke execute on function public.update_my_settings(
  boolean, boolean, boolean, boolean, boolean, boolean, text) from public, anon;
grant execute on function public.get_my_profile()            to authenticated;
grant execute on function public.update_my_settings(
  boolean, boolean, boolean, boolean, boolean, boolean, text) to authenticated;
