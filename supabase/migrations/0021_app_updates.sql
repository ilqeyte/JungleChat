-- ============================================================================
-- 0021_app_updates.sql — in-app update delivery (admin upload -> user install)
--
-- WHY THIS FILE EXISTS
--   The update system was shipped to production WITHOUT a migration: the
--   objects exist there but were never committed (migration numbers 0009 and
--   0013 are absent from this repo). This file is the authoritative,
--   idempotent definition so repo and production match, and it fixes the
--   defects that made admin publishing fail with "Something went wrong."
--
-- DEFECTS FIXED HERE
--   1. Optional RPC parameters now carry DEFAULTs. The deployed
--      admin_create_update required p_required_after, while postgrest-dart
--      omits map keys whose value is null. A publish without a
--      "required after" date therefore produced PostgREST PGRST202, which
--      SafeErrors rendered as the generic failure message.
--   2. admin_publish_update() links the APK, activates the release and fans
--      out notifications in ONE call. The old client path made three calls
--      and never activated anything, so users were never told.
--   3. admin_list_updates() is gated by private.is_admin(). The deployed
--      version returned every update row to any anonymous caller.
--   4. The APK is delivered by DOWNLOAD URL, not by Supabase Storage.
--
-- WHY NOT SUPABASE STORAGE
--   The release APK is ~127 MiB. Supabase's free plan caps the global file
--   size limit at 50 MB, and a per-bucket limit may never exceed the global
--   one, so no bucket configuration can accept this file. The APK therefore
--   lives in a Cloudflare R2 bucket (no egress fees, no size cap) and this
--   table stores only the resulting https URL. The admin has two ways to
--   publish:
--     a) upload straight to R2 from the admin sheet (pre-signed PUT minted
--        server-side by the r2-upload-url Edge Function), or
--     b) paste a download link they host themselves.
--   Both end up in the same download_url column, so the client has exactly
--   one download path.
--
-- TRUST MODEL (AGENTS.md)
--   * Every admin entry point calls private.is_admin() first and raises one
--     opaque 'NOT_ADMIN'. No user enumeration, no detail leakage.
--   * Users have exactly one read path, get_latest_update(), which exposes
--     only version metadata, the changelog and the download URL.
--   * The R2 credentials NEVER reach the client. An APK can be decompiled,
--     so anything shipped in the Flutter binary is public. Only the Edge
--     Function holds them.
--   * download_url is validated to be https. An APK installed over plain
--     http is trivially replaceable in transit, and this URL drives a
--     package install on the user's device.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table
-- ----------------------------------------------------------------------------
create table if not exists public.app_updates (
  id             uuid primary key default gen_random_uuid(),
  version_code   integer     not null,
  version_name   text        not null,
  changelog      text        not null default '',
  download_url   text,
  file_size      bigint      not null default 0,
  is_required    boolean     not null default false,
  required_after timestamptz,
  is_active      boolean     not null default false,
  published_at   timestamptz,
  created_at     timestamptz not null default now(),
  constraint app_updates_code_chk check (version_code > 0)
);

-- Production already has this table (created ad-hoc, never migrated), so
-- `create table if not exists` above is a no-op there. Make the new column
-- arrive either way.
alter table public.app_updates add column if not exists download_url text;

-- Legacy column from the abandoned Supabase Storage attempt. Kept only so a
-- production row that still holds a value is not destroyed; nothing reads it.
alter table public.app_updates add column if not exists apk_path text;

create index if not exists app_updates_active_idx
  on public.app_updates (is_active) where is_active;
create index if not exists app_updates_code_idx
  on public.app_updates (version_code desc);

-- Exactly one release may be live at a time.
create unique index if not exists app_updates_one_active_idx
  on public.app_updates ((true)) where is_active;

alter table public.app_updates enable row level security;
alter table public.app_updates force row level security;

-- Writes are denied outright: every mutation goes through the admin_*
-- SECURITY DEFINER functions below.
drop policy if exists app_updates_no_direct_insert on public.app_updates;
drop policy if exists app_updates_no_direct_update on public.app_updates;
drop policy if exists app_updates_no_direct_delete on public.app_updates;

-- Reads: ONLY the live release, and only to signed-in users.
--
-- At first glance this duplicates get_latest_update(). It exists for Realtime:
-- postgres_changes events are filtered by RLS, so an app that is already open
-- would never hear "a release went live" without a SELECT policy. Exposing
-- exactly the active row leaks nothing beyond what get_latest_update() already
-- returns.
drop policy if exists app_updates_read_active on public.app_updates;
create policy app_updates_read_active
  on public.app_updates for select to authenticated
  using (is_active);

-- Realtime needs full row data on UPDATE so an open app learns about a newly
-- published release straight away.
alter table public.app_updates replica identity full;

-- ----------------------------------------------------------------------------
-- Shared admin guard
-- ----------------------------------------------------------------------------
-- One opaque error for every failure mode. Never reveals whether the caller
-- is simply not an admin or lacks the MFA-elevated (aal2) session.
create or replace function private.assert_admin_or_throw()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;
end;
$$;

-- Boolean probe for server-side callers (Edge Functions) that need to gate on
-- admin status. It exists so a function NEVER re-implements the admin rule in
-- TypeScript: if private.is_admin() changes, this changes with it. It answers
-- only "am I an admin?", which the caller already knows, so it leaks nothing.
create or replace function public.is_current_user_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_admin();
$$;

revoke all on function public.is_current_user_admin() from public;
grant execute on function public.is_current_user_admin() to authenticated;

-- ----------------------------------------------------------------------------
-- Shared URL guard
-- ----------------------------------------------------------------------------
-- The download URL drives a package install on a user's device, so it is
-- held to a stricter standard than an ordinary text field: https only,
-- bounded length, and no characters that could break out of a JSON payload
-- or inject a scheme. Rejecting http is deliberate — an APK fetched over
-- cleartext can be swapped in transit.
create or replace function private.assert_https_url(p_url text)
returns void
language plpgsql
immutable
as $$
begin
  if p_url is null
     or length(p_url) > 2048
     or p_url !~ '^https://[^[:space:]<>''"]+$' then
    raise exception 'INVALID_DOWNLOAD_URL' using errcode = '22023';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- USER READ PATH
-- ----------------------------------------------------------------------------

-- The only read a client needs: "is there a newer build for me?".
-- Returns at most one row (the live release).
create or replace function public.get_latest_update()
returns table (
  id             uuid,
  version_code   integer,
  version_name   text,
  changelog      text,
  download_url   text,
  file_size      bigint,
  is_required    boolean,
  required_after timestamptz,
  is_active      boolean,
  published_at   timestamptz,
  created_at     timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  select u.id, u.version_code, u.version_name, u.changelog, u.download_url,
         u.file_size, u.is_required, u.required_after, u.is_active,
         u.published_at, u.created_at
    from public.app_updates u
   where u.is_active
   order by u.version_code desc
   limit 1;
$$;

revoke all on function public.get_latest_update() from public;
grant execute on function public.get_latest_update() to anon, authenticated;

-- ----------------------------------------------------------------------------
-- ADMIN WRITE PATH
-- ----------------------------------------------------------------------------

-- Step 1 of 2: create the release row and hand back its id, so the client can
-- upload the APK to a server-assigned storage path.
--
-- p_changelog / p_is_required / p_required_after all have DEFAULTs on purpose:
-- the client omits keys it has no value for, and PostgREST must still resolve.
create or replace function public.admin_create_update(
  p_version_code   integer,
  p_version_name   text        default null,
  p_changelog      text        default '',
  p_is_required    boolean     default false,
  p_required_after timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id     uuid;
  v_name   text;
begin
  perform private.assert_admin_or_throw();

  if p_version_code is null or p_version_code < 1 then
    raise exception 'INVALID_VERSION' using errcode = '22023';
  end if;

  v_name := coalesce(nullif(btrim(p_version_name), ''), p_version_code::text);

  insert into public.app_updates (version_code, version_name, changelog,
                                  is_required, required_after)
  values (
    p_version_code,
    v_name,
    coalesce(p_changelog, ''),
    coalesce(p_is_required, false),
    -- "Required" with no grace date means required immediately.
    case
      when coalesce(p_is_required, false)
        then coalesce(p_required_after, now())
      else null
    end
  )
  returning id into v_id;

  insert into public.moderation_actions (admin_id, action, target_type,
                                         target_id, reason)
  values ((select auth.uid()), 'update_create', 'app_update', v_id::text,
          'v' || v_name);

  return v_id;
end;
$$;

revoke all on function public.admin_create_update(integer, text, text, boolean, timestamptz) from public;
grant execute on function public.admin_create_update(integer, text, text, boolean, timestamptz) to authenticated;

-- Step 2 of 2: attach the download URL, go live, and notify everyone. One
-- round trip means the client can never leave a release half-published.
--
-- p_download_url is an absolute https URL pointing at the APK, either the
-- Cloudflare R2 object the admin just uploaded or a link they host
-- themselves. It is never a storage path.
create or replace function public.admin_publish_update(
  p_update_id    uuid,
  p_download_url text,
  p_file_size    bigint default 0
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version_name text;
  v_version_code integer;
begin
  perform private.assert_admin_or_throw();
  perform private.assert_https_url(p_download_url);

  -- Deactivate everything else BEFORE activating this release. The partial
  -- unique index app_updates_one_active_idx is checked per statement, so
  -- activating first would make the second-ever publish fail on a unique
  -- violation.
  update public.app_updates
     set is_active = false
   where id <> p_update_id
     and is_active;

  update public.app_updates
     set download_url = p_download_url,
         file_size    = greatest(coalesce(p_file_size, 0), 0),
         is_active    = true,
         published_at = coalesce(published_at, now())
   where id = p_update_id
  returning version_name, version_code into v_version_name, v_version_code;

  if not found then
    raise exception 'UPDATE_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Fan out to every live account. The payload carries NO animal id, room
  -- name or message preview — only the version, so the push template and the
  -- notification row both stay privacy-safe.
  insert into public.notifications (user_id, kind, payload)
  select p.id,
         'app_update',
         jsonb_build_object(
           'version_code', v_version_code,
           'version_name', v_version_name
         )
    from public.profiles p
   where p.deleted_at is null
     and p.status <> 'banned';

  insert into public.moderation_actions (admin_id, action, target_type,
                                         target_id, reason)
  values ((select auth.uid()), 'update_publish', 'app_update',
          p_update_id::text, 'v' || v_version_name);
end;
$$;

revoke all on function public.admin_publish_update(uuid, text, bigint) from public;
grant execute on function public.admin_publish_update(uuid, text, bigint) to authenticated;

-- Repoint an already-published release at a different APK without
-- re-publishing (no new notification fan-out).
create or replace function public.admin_set_update_url(
  p_update_id    uuid,
  p_download_url text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_admin_or_throw();
  perform private.assert_https_url(p_download_url);
  update public.app_updates
     set download_url = p_download_url
   where id = p_update_id;
  if not found then
    raise exception 'UPDATE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.admin_set_update_url(uuid, text) from public;
grant execute on function public.admin_set_update_url(uuid, text) to authenticated;

-- Retired with the move off Supabase Storage. Dropped rather than left in
-- place: it accepted a bucket-relative path that no longer means anything,
-- and every caller is now on the URL-based function above.
drop function if exists public.admin_set_update_apk(uuid, text);

create or replace function public.admin_set_active_update(p_update_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_admin_or_throw();

  -- Deactivate first: see the ordering note in admin_publish_update.
  update public.app_updates
     set is_active = false
   where id <> p_update_id and is_active;

  update public.app_updates
     set is_active    = true,
         published_at = coalesce(published_at, now())
   where id = p_update_id;
  if not found then
    raise exception 'UPDATE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.admin_set_active_update(uuid) from public;
grant execute on function public.admin_set_active_update(uuid) to authenticated;

create or replace function public.admin_toggle_update_required(
  p_update_id      uuid,
  p_is_required    boolean,
  p_required_after timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_admin_or_throw();
  update public.app_updates
     set is_required    = coalesce(p_is_required, false),
         required_after = case
                            when coalesce(p_is_required, false)
                              then coalesce(p_required_after, now())
                            else null
                          end
   where id = p_update_id;
  if not found then
    raise exception 'UPDATE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.admin_toggle_update_required(uuid, boolean, timestamptz) from public;
grant execute on function public.admin_toggle_update_required(uuid, boolean, timestamptz) to authenticated;

-- Admin listing. GATED: the deployed version leaked rows to anonymous callers.
create or replace function public.admin_list_updates()
returns table (
  id             uuid,
  version_code   integer,
  version_name   text,
  changelog      text,
  download_url   text,
  file_size      bigint,
  is_required    boolean,
  required_after timestamptz,
  is_active      boolean,
  published_at   timestamptz,
  created_at     timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  perform private.assert_admin_or_throw();
  return query
    select u.id, u.version_code, u.version_name, u.changelog, u.download_url,
           u.file_size, u.is_required, u.required_after, u.is_active,
           u.published_at, u.created_at
      from public.app_updates u
     order by u.version_code desc;
end;
$$;

revoke all on function public.admin_list_updates() from public;
grant execute on function public.admin_list_updates() to authenticated;

-- Deletes the release row. The APK is deliberately left in R2: this function
-- has no R2 credentials, and deleting it would silently break any device that
-- already cached the URL. Remove stale objects from the R2 dashboard.
create or replace function public.admin_delete_update_cascade(p_update_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_admin_or_throw();

  delete from public.app_updates where id = p_update_id;
  if not found then
    raise exception 'UPDATE_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.moderation_actions (admin_id, action, target_type,
                                         target_id, reason)
  values ((select auth.uid()), 'update_delete', 'app_update', p_update_id::text, '');
end;
$$;

revoke all on function public.admin_delete_update_cascade(uuid) from public;
grant execute on function public.admin_delete_update_cascade(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- NO STORAGE BUCKET, ON PURPOSE
-- ----------------------------------------------------------------------------
-- An earlier revision of this file created a public `updates` bucket with a
-- 256 MiB limit. It could never have worked: Supabase's free plan caps the
-- global file size limit at 50 MB, and a bucket limit may not exceed the
-- global one, so every ~127 MiB upload was rejected at the API edge.
--
-- The APK now lives in Cloudflare R2. To publish:
--   1. Call the r2-upload-url Edge Function to get a pre-signed PUT URL.
--   2. PUT the APK straight from the device to R2 (no Supabase hop, so no
--      size ceiling and no Edge Function body limit).
--   3. Call admin_publish_update() with the returned public https URL.
-- Alternatively paste any https link you control.
--
-- Required Edge Function secrets (never in the client):
--   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
--   R2_BUCKET, R2_PUBLIC_BASE

-- ----------------------------------------------------------------------------
-- REALTIME — lets an app that is already open hear "a release went live" now.
-- ----------------------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.app_updates;
exception
  when duplicate_object then null;
  when others then null;
end;
$$;

-- ----------------------------------------------------------------------------
-- PUSH TEMPLATE
-- ----------------------------------------------------------------------------
-- supabase/functions/push-worker/index.ts maps notification kinds to title and
-- body. Add this case so 'app_update' does not fall through to the generic
-- "Something happened in the shadows." line:
--
--   case "app_update":
--     return { title: "JungleChat", body: "A new version is available." };
--
-- The cron runs the worker every minute, so the fan-out above reaches devices
-- within about a minute of publishing.
-- ============================================================================
