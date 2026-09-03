-- ============================================================================
-- JUNGLECHAT — 0016_rewarded_ad_changes.sql
--
-- Monetization: animal changes are gated behind rewarded ads.
--   2 completed ad changes per day, enforced server-side.
--   Ad session tokens: issued on demand, single-use, 15-min expiry.
--   Cancelling the ad = session left unused = no quota consumed.
--   Sample ad provider now; real network plugs in later.
-- ============================================================================

create table if not exists public.ad_sessions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  used_at    timestamptz
);

alter table public.ad_sessions enable row level security;
alter table public.ad_sessions force row level security;
revoke all on public.ad_sessions from public, anon, authenticated;
create index if not exists ad_sessions_user_idx on public.ad_sessions (user_id, created_at desc);

-- ad_change_quota: how many changes used/remaining today.
create or replace function public.ad_change_quota()
returns table (used_today int, remaining_today int)
language sql stable security definer set search_path = ''
as $$
  select count(*)::int,
         greatest(0, 2 - count(*))::int
    from public.ad_sessions
   where user_id = auth.uid()
     and used_at is not null
     and created_at >= date_trunc('day', now());
$$;
revoke execute on function public.ad_change_quota() from public, anon;
grant  execute on function public.ad_change_quota() to authenticated;

-- begin_ad_change: issue a single-use session (requires quota remaining).
create or replace function public.begin_ad_change()
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_used int; v_id uuid;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('ad_begin', coalesce(auth.uid()::text, private.client_ip()), 12, interval '1 hour');
  select count(*)::int into v_used
    from public.ad_sessions
   where user_id = auth.uid() and used_at is not null
     and created_at >= date_trunc('day', now());
  if v_used >= 2 then raise exception 'AD_QUOTA_EXHAUSTED'; end if;
  insert into public.ad_sessions (user_id) values (auth.uid()) returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.begin_ad_change() from public, anon;
grant  execute on function public.begin_ad_change() to authenticated;

-- complete_ad_change: consume session + perform the change atomically.
create or replace function public.complete_ad_change(p_session uuid, p_new_animal text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid(); v_new text := initcap(btrim(coalesce(p_new_animal,'')));
  v_old text; v_num int; v_display text; v_ok boolean;
begin
  perform private.ensure_active_account();
  update public.ad_sessions set used_at = now()
   where id = p_session and user_id = v_me and used_at is null and expires_at > now()
   returning true into v_ok;
  if v_ok is null then raise exception 'AD_SESSION_INVALID'; end if;
  if (select count(*)::int from public.ad_sessions
       where user_id = v_me and used_at is not null
         and created_at >= date_trunc('day', now())) > 2 then
    raise exception 'AD_QUOTA_EXHAUSTED';
  end if;
  if not exists (select 1 from private.animal_catalog where animal = v_new) then
    raise exception 'INVALID_ANIMAL';
  end if;
  select animal, animal_number into v_old, v_num from public.profiles where id = v_me;
  if v_old is null then raise exception 'ACCOUNT_NOT_FOUND'; end if;
  perform pg_advisory_xact_lock(hashtext('junglechat|alloc|' || v_new));
  update public.animal_id set user_id = null, released_at = now() where animal = v_old and user_id = v_me;
  update public.animal_id a set user_id = v_me, allocated_at = now(), released_at = null
   where a.animal = v_new and a.user_id is null and a.released_at is not null
     and a.number = (select min(a2.number) from public.animal_id a2
                      where a2.animal = v_new and a2.user_id is null and a2.released_at is not null)
   returning a.number into v_num;
  if v_num is null then
    select coalesce(max(a.number),0)+1 into v_num from public.animal_id a where a.animal = v_new;
    insert into public.animal_id (animal, number, user_id) values (v_new, v_num, v_me);
  end if;
  v_display := upper(v_new) || '-' || v_num::text;
  update public.profiles set animal = v_new, animal_number = v_num, display_animal_id = v_display where id = v_me;
  perform private.touch_activity();
  return v_display;
end;
$$;
revoke execute on function public.complete_ad_change(uuid,text) from public, anon;
grant  execute on function public.complete_ad_change(uuid,text) to authenticated;

-- Changes are now ad-gated. The function is defined later (0027/0041); the
-- actual EXECUTE revoke lives in 0312 once it exists. Guarded here so this
-- migration stays idempotent regardless of apply order.
do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'change_my_animal'
  ) then
    revoke execute on function public.change_my_animal(text) from public, anon, authenticated;
  end if;
end $$;