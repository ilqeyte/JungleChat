-- ============================================================================
-- JUNGLECHAT — 0041_change_animal_reuse_fix.sql
--
-- LIVE BUG (reproduced against production 2026-09-01): the ad-gated change
-- animal flow fails with
--   duplicate key value violates unique constraint "profiles_display_animal_id_key"
-- on complete_ad_change. Root cause is the SAME one 0040 fixed for signup:
-- admin_delete_user releases an animal_id slot but the tombstone profile row
-- keeps the unique display_animal_id for the 7-day undo window. The change
-- functions still claim "lowest released number" WITHOUT checking whether a
-- profile row (tombstone) still owns that display id -> profiles UPDATE hits
-- the unique violation and EVERY change into a species with released-but-
-- tombstoned numbers fails.
--
-- FIX: mirror 0040's tombstone-aware allocation into BOTH change functions:
--   - complete_ad_change(uuid, text)  (0016 — the ad-gated client path)
--   - change_my_animal(text)          (0027 — direct path, currently revoked
--                                      but kept consistent)
-- Released numbers whose display id is still claimed by ANY profile row are
-- skipped; allocation falls through to max+1. Also adds the missing
-- same-animal no-op early return to complete_ad_change (picking the current
-- species returns the current id instead of reallocating a new number).
-- ============================================================================

create or replace function public.complete_ad_change(p_session uuid, p_new_animal text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_new text := initcap(btrim(coalesce(p_new_animal,'')));
  v_old text; v_num int; v_display text; v_ok boolean;
begin
  perform private.ensure_active_account();

  select animal, animal_number into v_old, v_num from public.profiles where id = v_me;
  if v_old is null then raise exception 'ACCOUNT_NOT_FOUND'; end if;
  if v_old = v_new then
    return upper(v_new) || '-' || v_num::text;
  end if;

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

  perform pg_advisory_xact_lock(hashtext('junglechat|alloc|' || v_new));

  update public.animal_id set user_id = null, released_at = now()
   where animal = v_old and user_id = v_me;

  -- Reuse the lowest released number, BUT only if its display id is truly
  -- free: a soft-deleted tombstone profile still owns the display id for the
  -- 7-day undo window, so that number must be SKIPPED (0040 pattern).
  update public.animal_id a
     set user_id = v_me, allocated_at = now(), released_at = null
   where a.animal = v_new
     and a.user_id is null
     and a.released_at is not null
     and not exists (
       select 1 from public.profiles p2
        where p2.display_animal_id = upper(v_new) || '-' || a.number::text
     )
     and a.number = (select min(a2.number) from public.animal_id a2
                      where a2.animal = v_new and a2.user_id is null
                        and a2.released_at is not null
                        and not exists (
                          select 1 from public.profiles p3
                           where p3.display_animal_id = upper(v_new) || '-' || a2.number::text
                        ))
   returning a.number into v_num;

  if v_num is null then
    select coalesce(max(a.number), 0) + 1 into v_num
      from public.animal_id a where a.animal = v_new;
    begin
      insert into public.animal_id (animal, number, user_id) values (v_new, v_num, v_me);
    exception when unique_violation then
      select coalesce(max(a.number), 0) + 1 into v_num
        from public.animal_id a where a.animal = v_new;
      insert into public.animal_id (animal, number, user_id) values (v_new, v_num, v_me);
    end;
  end if;

  v_display := upper(v_new) || '-' || v_num::text;
  update public.profiles
     set animal = v_new, animal_number = v_num, display_animal_id = v_display
   where id = v_me;
  perform private.touch_activity();
  return v_display;
end;
$$;
revoke execute on function public.complete_ad_change(uuid,text) from public, anon;
grant  execute on function public.complete_ad_change(uuid,text) to authenticated;

-- ============================================================================
-- change_my_animal: same tombstone-aware allocation (kept consistent even
-- though execute is currently revoked from authenticated — 0016 ad-gating).
-- ============================================================================
create or replace function public.change_my_animal(p_new_animal text)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_me      uuid := auth.uid();
  v_new     text := initcap(btrim(coalesce(p_new_animal, '')));
  v_old     text;
  v_num     int;
  v_display text;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('change_animal', v_me::text, 3, interval '7 days');

  if not exists (select 1 from private.animal_catalog where animal = v_new) then
    raise exception 'INVALID_ANIMAL';
  end if;

  select animal, animal_number into v_old, v_num
    from public.profiles where id = v_me;
  if v_old is null then
    raise exception 'ACCOUNT_NOT_FOUND';
  end if;
  if v_old = v_new then
    return upper(v_new) || '-' || v_num::text;
  end if;

  perform pg_advisory_xact_lock(hashtext('junglechat|alloc|' || v_new));

  update public.animal_id
     set user_id = null, released_at = now()
   where animal = v_old and user_id = v_me;

  update public.animal_id a
     set user_id = v_me, allocated_at = now(), released_at = null
   where a.animal = v_new
     and a.user_id is null
     and a.released_at is not null
     and not exists (
       select 1 from public.profiles p2
        where p2.display_animal_id = upper(v_new) || '-' || a.number::text
     )
     and a.number = (select min(a2.number) from public.animal_id a2
                      where a2.animal = v_new and a2.user_id is null
                        and a2.released_at is not null
                        and not exists (
                          select 1 from public.profiles p3
                           where p3.display_animal_id = upper(v_new) || '-' || a2.number::text
                        ))
   returning a.number into v_num;

  if v_num is null then
    select coalesce(max(a.number), 0) + 1 into v_num
      from public.animal_id a where a.animal = v_new;
    begin
      insert into public.animal_id (animal, number, user_id) values (v_new, v_num, v_me);
    exception when unique_violation then
      select coalesce(max(a.number), 0) + 1 into v_num
        from public.animal_id a where a.animal = v_new;
      insert into public.animal_id (animal, number, user_id) values (v_new, v_num, v_me);
    end;
  end if;

  v_display := upper(v_new) || '-' || v_num::text;

  update public.profiles
     set animal = v_new, animal_number = v_num, display_animal_id = v_display
   where id = v_me;

  return v_display;
end;
$function$;
