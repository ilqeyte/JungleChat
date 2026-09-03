-- ============================================================================
-- JungleChat — Admin bootstrap
-- ----------------------------------------------------------------------------
-- Creates the FIRST administrator account and grants it the admin role so the
-- Flutter web admin panel can be used. The panel enforces MFA (aal2), so after
-- this account's first password sign-in it will prompt to enroll a TOTP
-- authenticator app — that is the intended, secure flow.
--
-- HOW TO RUN
--   Option A (Supabase dashboard): open SQL Editor, paste this, click Run.
--   Option B (CLI):  supabase db query --linked -f scripts/bootstrap_admin.sql
--
-- SECURITY
--   Replace CHANGE_ME_STRONG_PASSWORD with a strong, unique password. This is
--   a bootstrap credential — change it immediately after handover (rotate the
--   password in the Supabase Auth dashboard). Never commit a real password to
--   this file.
-- ============================================================================

do $$
declare
  v_uid uuid;
  v_email text := 'admin@junglechat.app';
  v_pw    text := 'CHANGE_ME_STRONG_PASSWORD';
begin
  if not exists (select 1 from auth.users where email = v_email) then
    insert into auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    values (gen_random_uuid(), v_email, crypt(v_pw, gen_salt('bf')), now(), now(), now())
    returning id into v_uid;
  else
    select id into v_uid from auth.users where email = v_email;
  end if;

  if not exists (select 1 from auth.identities where user_id = v_uid and provider = 'email') then
    insert into auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid,
            jsonb_build_object('sub', v_uid::text, 'email', v_email, 'provider_id', v_email),
            'email', v_email, now(), now(), now());
  end if;

  if not exists (select 1 from public.admin_roles where user_id = v_uid) then
    insert into public.admin_roles (user_id) values (v_uid);
  end if;
end $$;
