-- ============================================================================
-- JUNGLECHAT — 0044_change_animal_alloc_hardening.sql
--
-- Closes a LATENT hole left by 0041 in both change functions.
--
-- 0041 made the "reuse a released number" path tombstone-aware. The FALLBACK
-- path was not:
--
--     select coalesce(max(a.number), 0) + 1 into v_num ...
--     insert into public.animal_id (animal, number, user_id) values (...)
--
-- max()+1 is assumed free, but a display id can be owned by a profile row
-- that has NO matching animal_id row — a soft-deleted tombstone whose slot
-- was hard-removed, or a row repaired by hand. When that tombstone's number
-- sits at or above max()+1, max()+1 lands exactly on its display id and the
-- final `update public.profiles set display_animal_id = ...` raises
--   duplicate key value violates unique constraint
--   "profiles_display_animal_id_key"
-- which is the same class of failure 0041 was written to kill. The user
-- watches a full rewarded ad and gets nothing.
--
-- Verified against production 2026-09-01: 49 profiles, 28 tombstoned, 31
-- released slots, ALL 31 still owned by a tombstone, 0 profiles missing a
-- slot row, 0 profiles sitting on max()+1. So the crash is NOT live today —
-- this migration removes the landmine before data drifts into it, rather
-- than after.
--
-- FIX: after computing max()+1, step the candidate forward until its display
-- id is unclaimed by ANY profile row. The unique_violation retry is kept for
-- parity with 0041.
--
-- NOTE ON WHY REUSE IS EFFECTIVELY DEAD IN PRACTICE
-- ---------------------------------------------------------------------------
-- Because admin_delete_user keeps the tombstone profile (and therefore its
-- unique display id) for the 7-day undo window, every released number is
-- tombstone-owned until that tombstone is hard-deleted. Production currently
-- has 31 released slots and all 31 are tombstone-owned, so allocation always
-- falls through to max()+1 and numbers only ever grow. That is correct and
-- safe behaviour — the unique constraint must win over prettier low numbers.
-- Do not "fix" it by reusing tombstoned numbers; it would reintroduce the
-- exact duplicate-key crash this file and 0041 exist to prevent.
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

  -- Reuse the lowest released number whose display id is truly free.
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
    -- Skip forward past any number whose display id is still claimed.
    while exists (
      select 1 from public.profiles p2
       where p2.display_animal_id = upper(v_new) || '-' || v_num::text
    ) loop
      v_num := v_num + 1;
    end loop;
    begin
      insert into public.animal_id (animal, number, user_id) values (v_new, v_num, v_me);
    exception when unique_violation then
      select coalesce(max(a.number), 0) + 1 into v_num
        from public.animal_id a where a.animal = v_new;
      while exists (
        select 1 from public.profiles p3
         where p3.display_animal_id = upper(v_new) || '-' || v_num::text
      ) loop
        v_num := v_num + 1;
      end loop;
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
-- change_my_animal: same hardening (direct path, currently revoked — 0016
-- ad-gating — but kept byte-consistent with the ad-gated path).
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
    while exists (
      select 1 from public.profiles p2
       where p2.display_animal_id = upper(v_new) || '-' || v_num::text
    ) loop
      v_num := v_num + 1;
    end loop;
    begin
      insert into public.animal_id (animal, number, user_id) values (v_new, v_num, v_me);
    exception when unique_violation then
      select coalesce(max(a.number), 0) + 1 into v_num
        from public.animal_id a where a.animal = v_new;
      while exists (
        select 1 from public.profiles p3
         where p3.display_animal_id = upper(v_new) || '-' || v_num::text
      ) loop
        v_num := v_num + 1;
      end loop;
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
