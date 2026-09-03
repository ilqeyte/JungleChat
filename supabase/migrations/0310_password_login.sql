-- ============================================================================
-- JUNGLECHAT — 0310_password_login.sql
--
-- Optional user-chosen password login, in addition to the recovery credential.
-- The recovery credential stays the canonical GoTrue password
-- (auth.users.encrypted_password). A separate bcrypt hash in
-- profiles.password_hash enables "Animal ID + password" login through the
-- login Edge Function, without ever overwriting the recovery credential.
-- ============================================================================

alter table public.profiles
  add column if not exists password_hash text;

comment on column public.profiles.password_hash is
  'bcrypt hash of the user-chosen password (nullable). The recovery credential remains the canonical auth password.';

-- ----------------------------------------------------------------------------
-- service_set_login_password(p_password)
-- Sets/replaces the current user's password. Authenticated callers only;
-- operates strictly on auth.uid().
-- ----------------------------------------------------------------------------
create or replace function public.service_set_login_password(p_password text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if coalesce(p_password, '') !~ '^.{8,128}$' then
    raise exception 'WEAK_PASSWORD';
  end if;
  perform private.rate_limit('set_password', v_uid::text, 5, interval '1 hour');
  update public.profiles
     set password_hash = extensions.crypt(p_password, extensions.gen_salt('bf', 10))
   where id = v_uid;
  return true;
end;
$$;

-- ----------------------------------------------------------------------------
-- service_verify_login_password(p_display_animal_id, p_password, p_client_ip)
-- Returns the internal login email when Animal ID + password match, else NULL.
-- Failure modes are indistinguishable by design. Service-role only (Edge Fn).
-- ----------------------------------------------------------------------------
create or replace function public.service_verify_login_password(
  p_display_animal_id text,
  p_password          text,
  p_client_ip         text default 'unknown'
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
        from public.profiles pr
       where pr.id = v_uid
         and pr.password_hash is not null
         and pr.password_hash = extensions.crypt(p_password, pr.password_hash)
    ) into v_ok;
  end if;

  if v_ok then
    update public.profiles set last_active_at = now() where id = v_uid;
    return v_email;
  end if;

  insert into public.security_events (event, actor_hint)
  values ('login.failed', left(private.subject_key('tgt|' || v_norm), 16));
  return null;
end;
$$;

-- ----------------------------------------------------------------------------
-- PRIVILEGES
-- ----------------------------------------------------------------------------
revoke execute on function public.service_set_login_password(text) from public, anon;
grant execute on function public.service_set_login_password(text) to authenticated;

revoke execute on function public.service_verify_login_password(text,text,text) from public, anon, authenticated;
grant execute on function public.service_verify_login_password(text,text,text) to service_role;
