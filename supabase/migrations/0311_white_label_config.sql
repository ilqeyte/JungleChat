-- ============================================================================
-- JUNGLECHAT — 0311_white_label_config.sql
--
-- Runtime white-label / branding settings, editable from the web admin panel.
-- The app reads these on launch with a safe local fallback, so a missing row
-- can never break the UI.
-- ============================================================================

create table if not exists public.app_config (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

insert into public.app_config (key, value, description) values
  ('app_name', '"JungleChat"', 'Display name of the app.'),
  ('tagline', '"No name. No face. Just you."', 'One-line marketing tagline shown on onboarding.'),
  ('brand', '{"primary_color":"#0B0B0B","accent_color":"#8FBF9F","background_color":"#000000"}',
    'Core brand colors as hex strings.'),
  ('support', '{"email":"support@junglechat.app","terms_url":"","privacy_url":""}',
    'Support contact and legal links.'),
  ('features', '{"reactions":true,"auto_delete":true,"app_lock":true,"groups":true}',
    'Feature toggles consumed by the client.')
on conflict (key) do nothing;

alter table public.app_config enable row level security;
alter table public.app_config force row level security;

drop policy if exists app_config_select on public.app_config;
create policy app_config_select on public.app_config
  for select to anon, authenticated using (true);

-- ----------------------------------------------------------------------------
-- get_app_config(): whole config as a single jsonb object.
-- ----------------------------------------------------------------------------
create or replace function public.get_app_config()
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from public.app_config;
$$;

-- ----------------------------------------------------------------------------
-- admin_set_app_config(p_key, p_value): admin-only write (aal2 enforced).
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_app_config(p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'FORBIDDEN';
  end if;
  insert into public.app_config (key, value, updated_by)
  values (p_key, p_value, auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = excluded.updated_by;
end;
$$;

-- ----------------------------------------------------------------------------
-- PRIVILEGES
-- ----------------------------------------------------------------------------
revoke execute on function public.get_app_config() from public, anon, authenticated;
grant execute on function public.get_app_config() to anon, authenticated;

revoke execute on function public.admin_set_app_config(text, jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_app_config(text, jsonb) to authenticated;
