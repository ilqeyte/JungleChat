-- ============================================================================
-- JUNGLECHAT — 0002_security_functions.sql
--
-- Internal helpers live in the `private` schema (never exposed via PostgREST).
-- Public RPCs are thin, rate-limited, fully server-authorized entry points.
--
-- Rules encoded here:
--   * Rate limiting is server-side only.
--   * last_active_at uses the SERVER clock, only on qualifying deliberate actions.
--   * Search is exact-match only; no enumeration lists.
--   * Discovery respects Open to Talk / Shadow Mode / blocks / account status.
-- ============================================================================

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- private.client_ip() — best-effort client IP from PostgREST request headers.
-- ----------------------------------------------------------------------------
create or replace function private.client_ip()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    split_part(nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1),
    current_setting('request.headers', true)::json ->> 'x-real-ip',
    'unknown'
  );
$$;

-- ----------------------------------------------------------------------------
-- private.subject_key(subject) — one-way hash so raw IPs never persist.
-- ----------------------------------------------------------------------------
create or replace function private.subject_key(p_subject text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(convert_to('in:' || coalesce(p_subject, 'unknown'), 'UTF8'), 'sha256'), 'hex');
$$;

-- ----------------------------------------------------------------------------
-- private.rate_limit(p_action, p_subject, p_max, p_window) — fixed-window
-- limiter. Raises RATE_LIMITED and records a security event when tripped.
-- ----------------------------------------------------------------------------
create or replace function private.rate_limit(
  p_action  text,
  p_subject text,
  p_max     int,
  p_window  interval
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key    text := private.subject_key(p_action || '|' || p_subject);
  v_bucket timestamptz := date_trunc('minute', now())
                          - (extract(epoch from date_trunc('minute', now()))::int % extract(epoch from p_window)::int) * interval '1 second';
  v_count  int;
begin
  insert into public.rate_limit_buckets (bucket_key, window_start, count)
  values (v_key, v_bucket, 1)
  on conflict (bucket_key, window_start)
    do update set count = public.rate_limit_buckets.count + 1
  returning count into v_count;

  -- Opportunistic cleanup of stale buckets (~4% of calls).
  if random() < 0.04 then
    delete from public.rate_limit_buckets where window_start < now() - interval '2 days';
  end if;

  if v_count > p_max then
    insert into public.security_events (event, actor_hint, details)
    values ('rate_limit.tripped', left(v_key, 16), jsonb_build_object('action', p_action));
    raise exception 'RATE_LIMITED' using hint = 'Too many requests. Try again later.';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- private.client_rate_limit(...) — convenience wrapper keyed by client IP.
-- ----------------------------------------------------------------------------
create or replace function private.client_rate_limit(p_action text, p_max int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rate_limit(p_action, private.client_ip(), p_max, p_window);
end;
$$;

-- ----------------------------------------------------------------------------
-- private.touch_activity() — qualifying deliberate action only. Server clock.
-- Never accepts client timestamps.
-- ----------------------------------------------------------------------------
create or replace function private.touch_activity()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles
     set last_active_at = now()
   where id = auth.uid()
     and deleted_at is null;
$$;

-- ----------------------------------------------------------------------------
-- private.is_admin() — admin role AND MFA-elevated session (aal2).
-- A stolen/low-assurance token can never pass.
-- ----------------------------------------------------------------------------
create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admin_roles r where r.user_id = auth.uid()
  )
  and coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;

-- ----------------------------------------------------------------------------
-- private.ensure_active_account() — must be active & not deleted.
-- ----------------------------------------------------------------------------
create or replace function private.ensure_active_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.account_status;
begin
  select status into v_status from public.profiles where id = auth.uid();
  if v_status is null then
    raise exception 'ACCOUNT_NOT_FOUND';
  end if;
  if v_status in ('suspended', 'banned') then
    raise exception 'ACCOUNT_RESTRICTED';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- private.blocked_between(a, b) — true when EITHER side blocked the other.
-- ----------------------------------------------------------------------------
create or replace function private.blocked_between(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = p_a and blocked_id = p_b)
       or (blocker_id = p_b and blocked_id = p_a)
  );
$$;

-- ============================================================================
-- PUBLIC RPCs — callable by authenticated users only.
-- All mutations of settings flow through here; clients have no direct write.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- get_my_profile — own profile + days until inactivity deletion.
-- ----------------------------------------------------------------------------
create or replace function public.get_my_profile()
returns table (
  id                uuid,
  display_animal_id text,
  animal            text,
  open_to_talk      boolean,
  random_talk_enabled boolean,
  status            public.account_status,
  days_until_delete int,
  created_at        timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.display_animal_id, p.animal, p.open_to_talk, p.random_talk_enabled,
         p.status,
         greatest(0, 90 - extract(day from now() - p.last_active_at)::int),
         p.created_at
    from public.profiles p
   where p.id = auth.uid() and p.deleted_at is null;
$$;

-- ----------------------------------------------------------------------------
-- update_my_settings — the ONLY way to change Open to Talk / Shadow Mode.
-- ----------------------------------------------------------------------------
create or replace function public.update_my_settings(
  p_open_to_talk  boolean,
  p_random_talk   boolean default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.ensure_active_account();
  perform private.client_rate_limit('update_settings', 30, interval '10 minutes');

  update public.profiles
     set open_to_talk        = coalesce(p_open_to_talk, open_to_talk),
         random_talk_enabled = coalesce(p_random_talk, random_talk_enabled)
   where id = auth.uid();

  perform private.touch_activity();
end;
$$;

-- ----------------------------------------------------------------------------
-- discoverable_card filter — shared predicate for every discovery surface:
-- visible only when: active, not deleted, open-to-talk (Shadow respected),
-- and neither side has blocked the other.
-- ----------------------------------------------------------------------------
create or replace function private.can_discover(p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.profiles t
     where t.id = p_target
       and t.deleted_at is null
       and t.status = 'active'
       and t.open_to_talk
       and not exists (
             select 1 from public.blocks b
              where (b.blocker_id = auth.uid() and b.blocked_id = t.id)
                 or (b.blocker_id = t.id and b.blocked_id = auth.uid())
           )
  );
$$;

-- ----------------------------------------------------------------------------
-- list_discoverable_animals — "Meet the Animals" (paginated, capped).
-- ----------------------------------------------------------------------------
create or replace function public.list_discoverable_animals(
  p_limit  int default 50,
  p_offset int default 0
)
returns table (
  id                uuid,
  animal            text,
  display_animal_id text,
  open_to_talk      boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.animal, t.display_animal_id, t.open_to_talk
    from public.profiles t
   where t.id <> auth.uid()
     and private.can_discover(t.id)
   order by t.created_at asc
   limit least(greatest(coalesce(p_limit, 50), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

-- ----------------------------------------------------------------------------
-- list_animal_kind — "Meet Your Animal" (same-animal discovery).
-- ----------------------------------------------------------------------------
create or replace function public.list_animal_kind(
  p_animal text,
  p_limit  int default 50,
  p_offset int default 0
)
returns table (
  id                uuid,
  animal            text,
  display_animal_id text,
  open_to_talk      boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.animal, t.display_animal_id, t.open_to_talk
    from public.profiles t
   where t.id <> auth.uid()
     and lower(t.animal) = lower(left(btrim(coalesce(p_animal, '')), 20))
     and private.can_discover(t.id)
   order by t.created_at asc
   limit least(greatest(coalesce(p_limit, 50), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

-- ----------------------------------------------------------------------------
-- search_animal_by_id — EXACT match only. No partial match, no wildcards.
-- Rate limited hard to defeat enumeration; block/shadow aware.
-- ----------------------------------------------------------------------------
create or replace function public.search_animal_by_id(p_query text)
returns table (
  id                uuid,
  animal            text,
  display_animal_id text,
  open_to_talk      boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_norm text := upper(btrim(coalesce(p_query, '')));
begin
  perform private.ensure_active_account();
  perform private.client_rate_limit('animal_search', 20, interval '10 minutes');

  if v_norm !~ '^[A-Z]{3,20}-[0-9]{1,6}$' then
    return;  -- malformed query: behave identically to "not found"
  end if;

  return query
  select t.id, t.animal, t.display_animal_id, t.open_to_talk
    from public.profiles t
   where t.display_animal_id = v_norm
     and t.id <> auth.uid()
     and private.can_discover(t.id)
   limit 1;
end;
$$;

-- ============================================================================
-- LOCK DOWN EXECUTE PRIVILEGES
-- Functions default to executable-by-public; revoke everywhere, then grant
-- deliberately. Internal helpers stay reachable by definer code only.
-- ============================================================================
revoke execute on function private.client_ip()                       from public, anon, authenticated;
revoke execute on function private.subject_key(text)                 from public, anon, authenticated;
revoke execute on function private.rate_limit(text,text,int,interval) from public, anon, authenticated;
revoke execute on function private.client_rate_limit(text,int,interval) from public, anon, authenticated;
revoke execute on function private.touch_activity()                  from public, anon, authenticated;
revoke execute on function private.is_admin()                        from public, anon, authenticated;
revoke execute on function private.ensure_active_account()           from public, anon, authenticated;
revoke execute on function private.blocked_between(uuid,uuid)        from public, anon, authenticated;
revoke execute on function private.can_discover(uuid)                from public, anon, authenticated;

revoke execute on function public.get_my_profile()                   from public, anon;
revoke execute on function public.update_my_settings(boolean,boolean) from public, anon;
revoke execute on function public.list_discoverable_animals(int,int) from public, anon;
revoke execute on function public.list_animal_kind(text,int,int)     from public, anon;
revoke execute on function public.search_animal_by_id(text)          from public, anon;

grant execute on function public.get_my_profile()                    to authenticated;
grant execute on function public.update_my_settings(boolean,boolean) to authenticated;
grant execute on function public.list_discoverable_animals(int,int)  to authenticated;
grant execute on function public.list_animal_kind(text,int,int)      to authenticated;
grant execute on function public.search_animal_by_id(text)           to authenticated;
