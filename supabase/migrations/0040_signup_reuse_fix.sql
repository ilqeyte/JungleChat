-- ============================================================================
-- JUNGLECHAT — 0040_signup_reuse_fix.sql
--
-- LIVE BUG (confirmed in production): after admin_delete_user releases an
-- Animal ID (animal_id.user_id = null, released_at = now), the tombstone
-- profile row STILL holds the unique display_animal_id for the 7-day undo
-- window. The reuse path in service_create_account picks that released
-- number, then the profiles INSERT fails with
-- duplicate key on profiles_display_animal_id_key
--   -> 500 ACCOUNT_CREATION_FAILED for EVERY new signup of that animal.
-- Production impact: Bear-2/3, Camel-3, Deer-2, Eagle-2/3, Falcon-3 were
-- all stuck — those animals were completely un-signuppable.
--
-- FIX: the reuse query skips released numbers whose display id is still
-- claimed by ANY existing profile row (soft-deleted tombstone). The signup
-- then allocates a FRESH number (max+1), so creation is unblocked
-- immediately. Released numbers become reusable again only after the
-- tombstone is hard-purged (admin hard delete cascades the profile row,
-- freeing display_animal_id) — the 7-day undo window stays intact.
-- ============================================================================

create or replace function public.service_create_account(
  p_animal text,
  p_recovery_credential text,
  p_client_ip text default 'unknown'
)
returns table(user_id uuid, display_animal_id text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid;
  v_num        int;
  v_display    text;
  v_email      text;
  v_norm       text := initcap(btrim(coalesce(p_animal, '')));
  v_ok_reuse   boolean;
begin
  perform private.rate_limit('account_create', coalesce(nullif(btrim(coalesce(p_client_ip,'')),''), 'unknown'), 20, interval '1 hour');

  if not exists (select 1 from private.animal_catalog where animal = v_norm) then
    raise exception 'INVALID_ANIMAL';
  end if;

  if coalesce(p_recovery_credential, '') !~ '^[A-Z0-9]{4}(-[A-Z0-9]{4}){4}$' then
    raise exception 'INVALID_CREDENTIAL_FORMAT';
  end if;

  v_uid := gen_random_uuid();
  v_email := v_uid::text || '@users.junglechat.internal';

  begin
    insert into auth.users (
      instance_id, id, aud, role, email,
      confirmation_token, email_change, email_change_token_new, recovery_token,
      encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',
      v_uid,
      'authenticated',
      'authenticated',
      v_email,
      '', '', '', '',
      extensions.crypt(p_recovery_credential, extensions.gen_salt('bf', 10)),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
      now(), now()
    );

    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (v_uid, v_uid, v_uid, 'email',
            jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
            now(), now(), now());
  exception when unique_violation then
    raise exception 'ACCOUNT_CREATION_FAILED';
  end;

  perform pg_advisory_xact_lock(hashtext('junglechat|alloc|' || v_norm));

  -- Reuse the lowest released number, BUT only if its display id is truly
  -- free: a soft-deleted tombstone profile still owns the display id for the
  -- 7-day undo window, so that number must be SKIPPED (it becomes reusable
  -- after the tombstone is hard-purged and the profile row is gone).
  update public.animal_id a
     set user_id = v_uid, allocated_at = now(), released_at = null
   where a.animal = v_norm
     and a.user_id is null
     and a.released_at is not null
     and not exists (
       select 1 from public.profiles p2
        where p2.display_animal_id = upper(v_norm) || '-' || a.number::text
     )
     and a.number = (select min(a2.number) from public.animal_id a2
                      where a2.animal = v_norm and a2.user_id is null
                        and a2.released_at is not null
                        and not exists (
                          select 1 from public.profiles p3
                           where p3.display_animal_id = upper(v_norm) || '-' || a2.number::text
                        ))
   returning true into v_ok_reuse;

  if v_ok_reuse is null then
    select coalesce(max(a.number), 0) + 1 into v_num from public.animal_id a where a.animal = v_norm;
    begin
      insert into public.animal_id (animal, number, user_id) values (v_norm, v_num, v_uid);
    exception when unique_violation then
      select coalesce(max(a.number), 0) + 1 into v_num from public.animal_id a where a.animal = v_norm;
      insert into public.animal_id (animal, number, user_id) values (v_norm, v_num, v_uid);
    end;
  end if;

  select a.number into v_num from public.animal_id a where a.animal = v_norm and a.user_id = v_uid;
  v_display := upper(v_norm) || '-' || v_num::text;

  insert into public.profiles (id, animal, animal_number, display_animal_id)
  values (v_uid, v_norm, v_num, v_display);

  return query select v_uid, v_display;
end;
$$;
