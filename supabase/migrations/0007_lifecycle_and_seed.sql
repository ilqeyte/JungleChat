-- ============================================================================
-- JUNGLECHAT — 0007_lifecycle_and_seed.sql
--
-- Inactivity policy (PRD §12–14):
--   * day 80/85/89 → one-time privacy-safe warning notifications
--   * day 90      → PERMANENT server-side account deletion
-- Deletion is idempotent, releases the Animal ID for reuse only after genuine
-- deletion, invalidates sessions, and never trusts client state.
--
-- Also: talk-request expiry, temporary-room expiry, and MVP seed data.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- expire_stale_requests — pending requests past expires_at become 'expired'.
-- ----------------------------------------------------------------------------
create or replace function public.expire_stale_requests()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  update public.talk_requests
     set status = 'expired', responded_at = now()
   where status = 'pending'
     and expires_at < now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ----------------------------------------------------------------------------
-- expire_temporary_rooms
-- ----------------------------------------------------------------------------
create or replace function public.expire_temporary_rooms()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  update public.rooms
     set is_active = false
   where kind = 'temporary'
     and is_active
     and expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ----------------------------------------------------------------------------
-- process_inactivity — warnings at 80/85/89; hard deletion at day >= 90.
-- Deletion order matters: sessions first, then auth user (cascades to profile,
-- memberships, messages sender FK set-null etc.), then release the Animal ID.
-- Idempotent: re-running on an already-deleted account changes nothing.
-- ----------------------------------------------------------------------------
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
     where p.deleted_at is null
       and p.last_active_at < now() - interval '80 days'
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

  -- Pass 2: deletion of accounts idle >= 90 days.
  for r in
    select p.id, a.animal, a.number
      from public.profiles p
      left join public.animal_id a on a.user_id = p.id
     where p.deleted_at is null
       and p.last_active_at < now() - interval '90 days'
     limit p_batch
  loop
    delete from auth.sessions       where user_id = r.id;
    delete from auth.refresh_tokens where user_id = r.id;

    -- Release the Animal ID BEFORE deleting the user row (animal_id.user_id is
    -- ON DELETE SET NULL; explicit release also stamps released_at).
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

revoke execute on function public.expire_stale_requests()        from public, anon, authenticated;
revoke execute on function public.expire_temporary_rooms()       from public, anon, authenticated;
revoke execute on function public.process_inactivity(int)        from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- Cron schedules (pg_cron). Guarded so migration stays rerunnable.
-- ----------------------------------------------------------------------------
create extension if not exists pg_cron;

do $do$
begin
  if not exists (select 1 from cron.job where jobname = 'junglechat-inactivity') then
    perform cron.schedule(
      'junglechat-inactivity', '17 3 * * *',
      $$ select public.process_inactivity(1000); $$
    );
  end if;

  if not exists (select 1 from cron.job where jobname = 'junglechat-expire-requests') then
    perform cron.schedule(
      'junglechat-expire-requests', '*/15 * * * *',
      $$ select public.expire_stale_requests(); $$
    );
  end if;

  if not exists (select 1 from cron.job where jobname = 'junglechat-expire-temp-rooms') then
    perform cron.schedule(
      'junglechat-expire-temp-rooms', '*/15 * * * *',
      $$ select public.expire_temporary_rooms(); $$
    );
  end if;
end;
$do$;

-- ============================================================================
-- SEED — animals available at onboarding (PRD §6) and built-in rooms (§22).
-- ============================================================================

insert into public.rooms (slug, name, description, kind) values
  ('junglechat', 'JungleChat', 'The general community. No name. No face. Just you.', 'builtin'),
  ('sheeko',      'Sheeko',      'Casual conversation. Tell us a story.',              'builtin'),
  ('qosol',       'Qosol',       'Jokes and fun. Keep it light.',                      'builtin'),
  ('soomaaliya',  'Soomaaliya',  'Somali discussions.',                                'builtin'),
  ('ardayda',     'Ardayda',     'Students and education.',                            'builtin'),
  ('technology',  'Technology',  'Technology, coding and AI.',                         'builtin'),
  ('ciyaaraha',   'Ciyaaraha',   'Sports.',                                            'builtin'),
  ('music',       'Music',       'Music.',                                             'builtin'),
  ('advice',      'Advice',      'Ask for advice, give advice.',                       'builtin'),
  ('debate',      'Debate',      'Structured debates. Keep it respectful.',            'builtin')
on conflict (slug) do nothing;