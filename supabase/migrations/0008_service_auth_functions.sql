-- ============================================================================
-- JUNGLECHAT — 0008_service_auth_functions.sql
--
-- Account creation + credential verification. Callable ONLY by the service
-- role (i.e. exclusively from trusted Edge Functions). Never granted to
-- anon/authenticated.
--
-- Recovery credential model (PRD §9):
--   * Generated with pgcrypto CSPRNG (gen_random_bytes), 20 chars from a
--     32-symbol unambiguous alphabet (~100 bits) formatted K7QM-4X9P-V2RT-…
--   * Stored ONLY as a bcrypt hash inside auth.users.encrypted_password.
--   * Returned exactly once to the client at creation. Never logged.
--   * Internal login email is a random UUID — NOT derived from the Animal ID,
--     making Animal-ID enumeration useless against the auth layer.
-- ============================================================================

-- Whitelist of animals available at onboarding.
create table private.animal_catalog (
  animal text primary key
);

insert into private.animal_catalog (animal) values
  ('Wolf'),('Lion'),('Eagle'),('Tiger'),('Fox'),('Bear'),('Owl'),('Panther'),
  ('Falcon'),('Camel'),('Elephant'),('Shark'),('Snake'),('Crocodile'),('Deer'),
  ('Horse'),('Gorilla'),('Hyena'),('Cheetah'),('Rabbit'),('Panda'),('Zebra'),
  ('Leopard'),('Hawk'),('Parrot'),('Dolphin'),('Whale'),('Turtle'),('Monkey'),
  ('Buffalo')
on conflict do nothing;

revoke all on private.animal_catalog from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- service_create_account(p_animal, p_recovery_credential, p_client_ip)
-- Returns (user_id, display_animal_id).
-- Atomic allocation: transaction-level advisory lock serializes per-animal;
-- unique(animal, number) backstops any theoretical race.
-- ----------------------------------------------------------------------------
create or replace function public.service_create_account(
  p_animal              text,
  p_recovery_credential text,
  p_client_ip           text default 'unknown'
)
returns table (user_id uuid, display_animal_id text)
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
  -- Server-side rate limit: account farming defense (per IP).
  perform private.rate_limit('account_create', coalesce(nullif(btrim(coalesce(p_client_ip,'')),''), 'unknown'), 5, interval '1 hour');

  if not exists (select 1 from private.animal_catalog where animal = v_norm) then
    raise exception 'INVALID_ANIMAL';
  end if;

  -- Credential sanity: normalized grouping must match A-Z0-9 groups.
  if coalesce(p_recovery_credential, '') !~ '^[A-Z0-9]{4}(-[A-Z0-9]{4}){4}$' then
    raise exception 'INVALID_CREDENTIAL_FORMAT';
  end if;

  v_uid := gen_random_uuid();
  v_email := v_uid::text || '@users.junglechat.internal';

  begin
    -- Auth identity FIRST: animal_id.user_id carries an FK to auth.users.
    -- bcrypt(cost 10) of the recovery credential. The raw value lives nowhere.
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
      extensions.crypt(p_recovery_credential, extensions.gen_salt('bf', 10)),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
      now(), now(),
      '', '', '', ''
    );

    -- GoTrue resolves password logins through auth.identities; a bare
    -- auth.users row is not enough for the token grant.
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (v_uid, v_uid, 'email', 'email',
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
      now(), now(), now()
    );
  exception when unique_violation then
    -- Astronomically unlikely UUID collision; fail loudly.
    raise exception 'ACCOUNT_CREATION_FAILED';
  end;

  -- ---- Atomic Animal ID allocation --------------------------------------
  perform pg_advisory_xact_lock(hashtext('junglechat|alloc|' || v_norm));

  -- Prefer recycling a RELEASED id: reassign the existing ledger row.
  update public.animal_id a
     set user_id     = v_uid,
         allocated_at = now(),
         released_at  = null
   where a.animal = v_norm
     and a.user_id is null
     and a.released_at is not null
     and a.number = (
       select min(a2.number) from public.animal_id a2
        where a2.animal = v_norm
          and a2.user_id is null
          and a2.released_at is not null
     )
   returning true into v_ok_reuse;

  if v_ok_reuse is null then
    -- Fresh number under this animal.
    select coalesce(max(a.number), 0) + 1 into v_num
      from public.animal_id a
     where a.animal = v_norm;

    begin
      insert into public.animal_id (animal, number, user_id)
      values (v_norm, v_num, v_uid);
    exception when unique_violation then
      -- Lost an impossible race under the lock: take next free number.
      select coalesce(max(a.number), 0) + 1 into v_num
        from public.animal_id a where a.animal = v_norm;
      insert into public.animal_id (animal, number, user_id)
      values (v_norm, v_num, v_uid);
    end;
  end if;

  select a.number into v_num
    from public.animal_id a
   where a.animal = v_norm
     and a.user_id = v_uid;

  v_display := upper(v_norm) || '-' || v_num::text;

  -- ---- Profile ------------------------------------------------------------
  insert into public.profiles (id, animal, animal_number, display_animal_id)
  values (v_uid, v_norm, v_num, v_display);

  return query select v_uid, v_display;
end;
$$;

-- ----------------------------------------------------------------------------
-- service_verify_login(p_display_animal_id, p_recovery_credential, p_client_ip)
-- Returns the internal login email ONLY on full success; NULL otherwise.
-- Deliberately indistinguishable outcomes: unknown Animal ID, deleted account,
-- suspended account, wrong credential, or malformed input.
-- ----------------------------------------------------------------------------
create or replace function public.service_verify_login(
  p_display_animal_id   text,
  p_recovery_credential text,
  p_client_ip           text default 'unknown'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_norm    text := upper(btrim(coalesce(p_display_animal_id, '')));
  v_ip_key  text := coalesce(nullif(btrim(coalesce(p_client_ip,'')),''), 'unknown');
  v_uid     uuid;
  v_email   text;
  v_ok      boolean := false;
begin
  -- Brute-force defenses: tight per-IP and per-target windows.
  perform private.rate_limit('login_ip', v_ip_key, 10, interval '15 minutes');
  perform private.rate_limit('login_target', left(v_norm, 40), 8, interval '1 hour');

  if v_norm !~ '^[A-Z]{3,20}-[0-9]{1,6}$' then
    return null;
  end if;

  select u.id, u.email into v_uid, v_email
    from public.profiles pr
    join auth.users u on u.id = pr.id
   where pr.display_animal_id = v_norm
     and pr.deleted_at is null;

  if v_uid is not null then
    select exists (
      select 1
        from auth.users u
       where u.id = v_uid
         and u.banned_until is null
         and u.encrypted_password = extensions.crypt(p_recovery_credential, u.encrypted_password)
    ) into v_ok;
  end if;

  if v_ok then
    -- Successful login IS qualifying activity (PRD §13).
    update public.profiles set last_active_at = now() where id = v_uid;
    return v_email;
  end if;

  -- Uniform failure telemetry: never reveals WHICH factor failed.
  insert into public.security_events (event, actor_hint)
  values ('login.failed', left(private.subject_key('tgt|' || v_norm), 16));
  return null;
end;
$$;

-- ----------------------------------------------------------------------------
-- PRIVILEGES: service role ONLY. Everyone else: nothing.
-- ----------------------------------------------------------------------------
revoke execute on function public.service_create_account(text,text,text) from public, anon, authenticated;
revoke execute on function public.service_verify_login(text,text,text)   from public, anon, authenticated;

grant execute on function public.service_create_account(text,text,text) to service_role;
grant execute on function public.service_verify_login(text,text,text)   to service_role;
