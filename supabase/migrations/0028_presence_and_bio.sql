-- ============================================================================
-- JUNGLECHAT - 0028_presence_and_bio.sql
--
-- Adds (a) user bio - optional, public, self-written profile blurb, and
-- (b) real-time online presence with a per-user show-online toggle in Settings,
-- (c) the client preference columns consumed by get_my_profile() /
--     update_my_settings(): typing_indicator_enabled and in_app_alerts.
--     (sounds_enabled / haptics_enabled were added earlier in 0014_sounds_haptics.)
--
-- DESIGN
--   Presence is SEPARATE from profiles.last_active_at. Charter rule 10 reserves
--   last_active_at for qualifying deliberate actions only. A dedicated presence
--   table is heartbeated by the foreground app. Online = heartbeat within 2
--   minutes. A user whose visibility_online=false is never shown as online.
-- ============================================================================

alter table public.profiles
  add column if not exists bio text,
  add column if not exists visibility_online boolean not null default true,
  add column if not exists typing_indicator_enabled boolean not null default true,
  add column if not exists in_app_alerts boolean not null default true;

alter table public.profiles
  add constraint profiles_bio_chk
    check (bio is null or char_length(bio) <= 160);

create table if not exists public.presence (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  last_seen  timestamptz not null default now()
);
create index presence_last_seen_idx on public.presence (last_seen);

alter table public.presence enable row level security;

drop policy if exists presence_upsert on public.presence;
create policy presence_upsert on public.presence for insert with check (user_id = auth.uid());
drop policy if exists presence_update on public.presence;
create policy presence_update on public.presence for update using (user_id = auth.uid());
drop policy if exists presence_select on public.presence;
create policy presence_select on public.presence for select using (true);

-- Existing functions whose RETURN row type is changing must be dropped first
-- (CREATE OR REPLACE cannot alter the output row type).
drop function if exists public.get_my_profile();
drop function if exists public.list_discoverable_animals(int, int);

create or replace function public.heartbeat()
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.presence (user_id, last_seen) values (auth.uid(), now())
  on conflict (user_id) do update set last_seen = now();
end;
$$;

create or replace function public.is_user_online(p_user uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.presence pr
    join public.profiles p on p.id = pr.user_id
    where pr.user_id = p_user
      and pr.last_seen > now() - interval '2 minutes'
      and p.visibility_online
  );
$$;

create or replace function public.get_my_profile()
returns table (
  id uuid, display_animal_id text, animal text, open_to_talk boolean,
  random_talk_enabled boolean, typing_indicator_enabled boolean,
  in_app_alerts boolean, sounds_enabled boolean, haptics_enabled boolean,
  status public.account_status, visibility_online boolean, bio text,
  is_online boolean, days_until_delete int, created_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select
    p.id, p.display_animal_id, p.animal, p.open_to_talk,
    p.random_talk_enabled, p.typing_indicator_enabled,
    p.in_app_alerts, p.sounds_enabled, p.haptics_enabled, p.status,
    p.visibility_online, p.bio,
    public.is_user_online(p.id),
    greatest(0, 90 - extract(day from now() - p.last_active_at)::int),
    p.created_at
  from public.profiles p
  where p.id = auth.uid() and p.deleted_at is null;
$$;

create or replace function public.update_my_settings(
  p_open_to_talk boolean default null, p_random_talk boolean default null,
  p_typing_indicator boolean default null, p_in_app_alerts boolean default null,
  p_sounds_enabled boolean default null, p_haptics_enabled boolean default null,
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
         sounds_enabled = coalesce(p_sounds_enabled, sounds_enabled),
         haptics_enabled = coalesce(p_haptics_enabled, haptics_enabled),
         visibility_online = coalesce(p_visibility_online, visibility_online),
         bio = coalesce(v_bio, bio)
   where id = auth.uid();
  perform private.touch_activity();
end;
$$;

create or replace function public.list_discoverable_animals(
  p_limit int default 50, p_offset int default 0
)
returns table (
  id uuid, animal text, display_animal_id text, open_to_talk boolean,
  bio text, is_online boolean
)
language sql stable security definer set search_path = ''
as $$
  select t.id, t.animal, t.display_animal_id, t.open_to_talk, t.bio,
         public.is_user_online(t.id)
  from public.profiles t
  where t.deleted_at is null and t.status = 'active' and t.open_to_talk
    and t.id <> auth.uid()
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = t.id)
         or (b.blocker_id = t.id and b.blocked_id = auth.uid()))
  order by t.open_to_talk desc, t.created_at desc
  limit greatest(least(coalesce(p_limit,50),200),1)
  offset greatest(coalesce(p_offset,0),0);
$$;

revoke execute on function public.heartbeat() from public, anon;
revoke execute on function public.is_user_online(uuid) from public, anon;
revoke execute on function public.get_my_profile() from public, anon;
revoke execute on function public.update_my_settings(boolean,boolean,boolean,boolean,boolean,boolean,boolean,text) from public, anon;
revoke execute on function public.list_discoverable_animals(int,int) from public, anon;

grant execute on function public.heartbeat() to authenticated;
grant execute on function public.is_user_online(uuid) to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.update_my_settings(boolean,boolean,boolean,boolean,boolean,boolean,boolean,text) to authenticated;
grant execute on function public.list_discoverable_animals(int,int) to authenticated;