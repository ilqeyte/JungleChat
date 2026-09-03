-- ============================================================================
-- 0304 — Remove the user soft-delete entirely (item #3).
--
-- One admin action, one outcome: the user is permanently gone from the app
-- database AND Supabase Auth. No undo, no grace period, no appeal step.
--
-- What this migration does, in order:
--   1. Drop submit_deletion_appeal (the appeal path is gone). The
--      'deletion_appeal' report_type enum value (0042) CANNOT be dropped in
--      PG 12+ — it is left in place and commented as deprecated.
--   2. Replace admin_delete_user with a stub that raises USE_ADMIN_HARD_DELETE_USER
--      (a loud, greppable failure if any client still calls the old RPC).
--   3. Drop admin_undo_delete_user.
--   4. Recreate the hot-path functions/policies/triggers that referenced
--      profiles.deleted_at, removing the filter. MESSAGE-level deleted_at
--      (direct_messages / group_messages / talk_requests) is a separate feature
--      and is deliberately untouched.
--   5. RETAIN the profiles.deleted_at column (do NOT drop it — see section 5/6
--      below for the rationale). Drop only the delete_undo_deadline column and
--      the profiles_deleted_chk check constraint.
--   6. Purge any account still carrying a soft-delete marker (step 1b) so no row
--      is left in limbo now that undo is gone.
--
-- Re-runnable: idempotent drops/recreates throughout.
-- ============================================================================

-- 1. Appeal RPC gone.
drop function if exists public.submit_deletion_appeal(text);

-- 1b. Purge lingering soft-deleted accounts (deleted_at set by the old RPC).
--     The undo path is gone, so leaving them orphaned is worse than deleting
--     them. Hard-delete through auth.users so the profile and all content cascade
--     away. 0303 guarantees the cascade no longer blocks on group_messages.deleted_by.
do $$
declare
  v_rec record;
begin
  for v_rec in
    select id from public.profiles where deleted_at is not null
  loop
    delete from auth.sessions       where user_id = v_rec.id;
    delete from auth.refresh_tokens where user_id = v_rec.id::text;
    delete from auth.users          where id = v_rec.id;
  end loop;
end $$;

-- 2. admin_delete_user → loud stub.
drop function if exists public.admin_delete_user(uuid);
create or replace function public.admin_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'USE_ADMIN_HARD_DELETE_USER'
    using errcode = 'P0001',
          hint = 'User soft-delete was removed. Call the admin-hard-delete-user edge function instead.';
end;
$$;
revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant  execute on function public.admin_delete_user(uuid) to authenticated;

-- 3. Undo RPC gone.
drop function if exists public.admin_undo_delete_user(uuid);

-- 4a. private.touch_activity — drop the deleted_at filter.
create or replace function private.touch_activity()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles
     set last_active_at = now()
   where id = auth.uid();
$$;

-- 4b. get_my_profile (authoritative body = 0301, minus the deleted_at filter).
drop function if exists public.get_my_profile();
create or replace function public.get_my_profile()
returns table (
  id uuid, display_animal_id text, animal text, open_to_talk boolean,
  random_talk_enabled boolean, typing_indicator_enabled boolean,
  in_app_alerts boolean, haptics_enabled boolean,
  status public.account_status, visibility_online boolean, bio text,
  is_online boolean, days_until_delete int, created_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select
    p.id, p.display_animal_id, p.animal, p.open_to_talk,
    p.random_talk_enabled, p.typing_indicator_enabled,
    p.in_app_alerts, p.haptics_enabled, p.status,
    p.visibility_online, p.bio,
    public.is_user_online(p.id),
    greatest(0, 90 - extract(day from now() - p.last_active_at)::int),
    p.created_at
  from public.profiles p
  where p.id = auth.uid();
$$;
revoke execute on function public.get_my_profile() from public, anon;
grant  execute on function public.get_my_profile() to authenticated;

-- 4c. get_animal_profile (0036, minus the deleted_at filter).
create or replace function public.get_animal_profile(p_user uuid)
returns table (
  id uuid, animal text, display_animal_id text, open_to_talk boolean,
  bio text, is_online boolean
)
language sql stable security definer set search_path = ''
as $$
  select p.id, p.animal, p.display_animal_id, p.open_to_talk, p.bio,
         public.is_user_online(p.id)
    from public.profiles p
   where p.id = p_user
     and p.status = 'active';
$$;
revoke execute on function public.get_animal_profile(uuid) from public, anon;
grant  execute on function public.get_animal_profile(uuid) to authenticated;

-- 4d. random_talk_candidate (0004, minus the deleted_at filter).
create or replace function public.random_talk_candidate()
returns table (
  id uuid, animal text, display_animal_id text, open_to_talk boolean
)
language sql stable security definer set search_path = ''
as $$
  select t.id, t.animal, t.display_animal_id, t.open_to_talk
    from (
      select *
        from public.profiles p
       where p.id <> auth.uid()
         and p.open_to_talk
         and p.random_talk_enabled
         and p.status = 'active'
         and not exists (
               select 1 from public.blocks b
                where (b.blocker_id = auth.uid() and b.blocked_id = p.id)
                   or (b.blocker_id = p.id and b.blocked_id = auth.uid())
             )
         and not exists (
               select 1 from public.talk_requests tr
                where tr.status = 'pending'
                  and ((tr.requester_id = auth.uid() and tr.target_id = p.id)
                    or (tr.target_id = auth.uid() and tr.requester_id = p.id))
             )
       limit 200
    ) t
   order by random()
   limit 1;
$$;

-- 4e. service_verify_login (0008, minus the pr.deleted_at filter).
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
  perform private.rate_limit('login_ip', v_ip_key, 10, interval '15 minutes');
  perform private.rate_limit('login_target', left(v_norm, 40), 8, interval '1 hour');

  if v_norm !~ '^[A-Z]{3,20}-[0-9]{1,6}$' then
    return null;
  end if;

  select u.id, u.email into v_uid, v_email
    from public.profiles pr
    join auth.users u on u.id = pr.id
   where pr.display_animal_id = v_norm;

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
    update public.profiles set last_active_at = now() where id = v_uid;
    return v_email;
  end if;

  insert into public.security_events (event, actor_hint)
  values ('login.failed', left(private.subject_key('tgt|' || v_norm), 16));
  return null;
end;
$$;

-- 4f. admin_publish_update (0021, minus the p.deleted_at filter).
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

  insert into public.notifications (user_id, kind, payload)
  select p.id,
         'app_update',
         jsonb_build_object(
           'version_code', v_version_code,
           'version_name', v_version_name
         )
    from public.profiles p
   where p.status <> 'banned';

  insert into public.moderation_actions (admin_id, action, target_type,
                                         target_id, reason)
  values ((select auth.uid()), 'update_publish', 'app_update',
          p_update_id::text, 'v' || v_version_name);
end;
$$;
revoke all on function public.admin_publish_update(uuid, text, bigint) from public;

-- 4g. process_inactivity (0035, authoritative body, minus the two
--     p.deleted_at is null filters — a present profile is now always active).
create or replace function public.process_inactivity(p_batch int default 500)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r          record;
  v_days     int;
  v_deleted  int := 0;
begin
  -- Pass 1: warnings (only for accounts still alive).
  for r in
    select p.id, p.inactivity_warning_sent,
           extract(day from now() - p.last_active_at)::int as days_idle
      from public.profiles p
     where p.last_active_at < now() - interval '80 days'
     limit p_batch
  loop
    if r.days_idle >= 89 then
      if r.inactivity_warning_sent < 89 then
        insert into public.notifications (user_id, kind, payload)
        values (r.id, 'inactivity_warning',
                jsonb_build_object('days_left', greatest(90 - r.days_idle, 0)));
        update public.profiles set inactivity_warning_sent = 89 where id = r.id;
      end if;
    elsif r.days_idle >= 85 then
      if r.inactivity_warning_sent < 85 then
        insert into public.notifications (user_id, kind, payload)
        values (r.id, 'inactivity_warning', jsonb_build_object('days_left', 5));
        update public.profiles set inactivity_warning_sent = 85 where id = r.id;
      end if;
    else
      if r.inactivity_warning_sent < 80 then
        insert into public.notifications (user_id, kind, payload)
        values (r.id, 'inactivity_warning', jsonb_build_object('days_left', 10));
        update public.profiles set inactivity_warning_sent = 80 where id = r.id;
      end if;
    end if;
  end loop;

  -- Pass 2: deletion of accounts idle >= 90 days (hard delete via auth.users;
  -- B2 is fixed in 0303 so the cascade no longer blocks).
  for r in
    select p.id, a.animal, a.number
      from public.profiles p
      left join public.animal_id a on a.user_id = p.id
     where p.last_active_at < now() - interval '90 days'
     limit p_batch
  loop
    delete from auth.sessions       where user_id = r.id;
    delete from auth.refresh_tokens where user_id = r.id::text;

    if r.animal is not null then
      update public.animal_id
         set released_at = now(), user_id = null
       where animal = r.animal and number = r.number;
    end if;

    insert into public.security_events (event, details)
    values ('account.inactivity_deleted', jsonb_build_object('user', r.id));

    delete from auth.users where id = r.id;   -- cascades everywhere else
    v_deleted := v_deleted + 1;
  end loop;

  return v_deleted;
end;
$$;
revoke all on function public.process_inactivity(int) from public, anon, authenticated;

-- 4h. admin_list_users (0026) — drop deleted_at + delete_undo_deadline from the
--     returned card. Soft-deleted rows no longer exist (hard delete removes the
--     profile row), so there is nothing to surface here.
drop function if exists public.admin_list_users();
create or replace function public.admin_list_users()
returns table (
  user_id           uuid,
  animal            text,
  animal_number     integer,
  display_animal_id text,
  status            text,
  open_to_talk      boolean,
  last_active_at    timestamp with time zone,
  created_at        timestamp with time zone
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  return query
    select
      p.id,
      ai.animal,
      ai.number,
      p.display_animal_id,
      p.status::text,
      p.open_to_talk,
      p.last_active_at,
      p.created_at
    from public.profiles p
    left join public.animal_id ai on ai.user_id = p.id
    order by p.created_at desc;
end;
$$;
revoke execute on function public.admin_list_users() from public, anon;
grant  execute on function public.admin_list_users() to authenticated;

-- 4i. profiles_select_discoverable policy — drop the deleted_at filter.
drop policy if exists profiles_select_discoverable on public.profiles;
create policy profiles_select_discoverable
  on public.profiles for select
  to authenticated
  using (
    status = 'active'
    and open_to_talk
    and id <> auth.uid()
    and not exists (
      select 1 from public.blocks b
       where (b.blocker_id = auth.uid() and b.blocked_id = profiles.id)
          or (b.blocker_id = profiles.id and b.blocked_id = auth.uid())
    )
  );

-- 4j. release_animal_id_on_profile_delete trigger — soft-delete (UPDATE) path
--     is gone; release only on actual DELETE (fires via the auth.users cascade).
drop trigger if exists trg_release_animal_id_on_profile_delete on public.profiles;
drop function if exists public.release_animal_id_on_profile_delete();
create or replace function public.release_animal_id_on_profile_delete()
returns trigger as $$
begin
  if (TG_OP = 'DELETE') then
    update public.animal_id
       set user_id = null, released_at = now()
     where user_id = OLD.id;
  end if;
  return NULL; -- trigger is AFTER, return value ignored
end;
$$ language plpgsql security definer;

drop trigger if exists trg_release_animal_id_on_profile_delete on public.profiles;
create trigger trg_release_animal_id_on_profile_delete
after delete on public.profiles
for each row execute function public.release_animal_id_on_profile_delete();

-- 5/6. Remove the soft-delete scaffolding that is safe to remove, and RETAIN
--     profiles.deleted_at. Several unrelated reader functions
--     (list_discoverable_animals, create_group, add_group_members,
--     send_group_invitations, …) still filter on `deleted_at is null`; with the
--     writers gone (step 2/3) the column is always NULL, so those filters are
--     harmless no-ops. Dropping the column would force recreating every one of
--     those functions and risk breaking the migration, so we leave the dead
--     column in place. The soft-delete behaviour is fully removed regardless:
--     the RPC is a stub, undo is dropped, nothing can SET deleted_at, and any
--     row that still carried the marker was purged in step 1b.
--     * profiles_deleted_chk encoded soft-delete semantics — drop it.
--     * delete_undo_deadline is no longer read or written anywhere — drop it.
alter table public.profiles drop constraint if exists profiles_deleted_chk;
alter table public.profiles drop column if exists delete_undo_deadline;
