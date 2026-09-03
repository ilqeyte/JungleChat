-- ============================================================================
-- JUNGLECHAT — 0006_admin_functions.sql
--
-- The "Adam" administrative backend. Every function requires:
--   1. An authenticated session whose user id exists in admin_roles, AND
--   2. A MFA-elevated session (JWT aal == aal2).
-- Hidden UI is NOT security — these gates are the security.
--
-- LEAST PRIVILEGE (PRD §36): admins may moderate PUBLIC surfaces and read
-- reports with minimal context only. No function here can read private chat
-- content, recovery credentials, or authentication secrets.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- private.admin_audit() — append-only audit writer.
-- ----------------------------------------------------------------------------
create or replace function private.admin_audit(p_event text, p_details jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.admin_audit_logs (actor_id, event, details)
  values (auth.uid(), p_event, p_details);
$$;

revoke execute on function private.admin_audit(text,jsonb) from public, anon, authenticated;

-- ============================================================================
-- REPORTS
-- ============================================================================

create or replace function public.admin_list_reports(
  p_status text default 'open',
  p_limit  int default 50
)
returns table (
  id                bigint,
  human_ref         text,
  type              public.report_type,
  status            public.report_status,
  body              text,
  created_at        timestamptz,
  reported_animal   text,
  reported_room     text,
  room_is_public    boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select rp.id, rp.human_ref, rp.type, rp.status, rp.body, rp.created_at,
         tp.display_animal_id,
         r.name,
         coalesce(r.kind in ('builtin','temporary') or not r.is_private, false)
    from public.reports rp
    left join public.profiles tp on tp.id = rp.target_user_id
    left join public.rooms   r  on r.id  = rp.target_room_id
   where rp.status = coalesce(p_status::public.report_status, rp.status)
   order by rp.created_at desc
   limit least(greatest(coalesce(p_limit,50),1),200);
$$;

-- ----------------------------------------------------------------------------
-- Message context for a report — ONLY when the message lives in a PUBLIC room.
-- Private conversations are unreachable by design; the query returns nothing.
-- ----------------------------------------------------------------------------
create or replace function public.admin_get_report_message_context(p_message uuid)
returns table (
  message_content text,
  sender_animal   text,
  room_name       text,
  sent_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select m.content, sp.display_animal_id, r.name, m.created_at
    from public.messages m
    join public.rooms r        on r.id = m.room_id
    join public.profiles sp    on sp.id = m.sender_id
   where m.id = p_message
     and m.deleted_at is null
     and r.is_active
     and (r.kind in ('builtin','temporary') or not r.is_private);
$$;

create or replace function public.admin_resolve_report(
  p_report bigint,
  p_status text,          -- investigating | resolved | dismissed
  p_note   text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_admin() <> true then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('investigating','resolved','dismissed') then
    raise exception 'INVALID_STATUS';
  end if;
  if char_length(coalesce(p_note,'')) > 1000 then raise exception 'INVALID_NOTE'; end if;

  update public.reports
     set status = p_status::public.report_status,
         resolution_note = nullif(btrim(p_note), ''),
         resolved_by = auth.uid()
   where id = p_report;

  perform private.admin_audit('report.resolved',
    jsonb_build_object('report', p_report, 'status', p_status));
end;
$$;

-- ============================================================================
-- PUBLIC MODERATION
-- ============================================================================

-- ----------------------------------------------------------------------------
-- admin_remove_message — PUBLIC messages only. The join against rooms with the
-- public predicate makes private-room messages structurally unreachable.
-- ----------------------------------------------------------------------------
create or replace function public.admin_remove_public_message(
  p_message uuid,
  p_reason  text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_admin() <> true then raise exception 'FORBIDDEN'; end if;
  if char_length(coalesce(p_reason,'')) > 500 then raise exception 'INVALID_REASON'; end if;

  update public.messages m
     set deleted_at = now(), deleted_by = auth.uid()
   where m.id = p_message
     and m.deleted_at is null
     and exists (
       select 1 from public.rooms r
        where r.id = m.room_id
          and (r.kind in ('builtin','temporary') or not r.is_private)
     );

  perform private.admin_audit('message.removed',
    jsonb_build_object('message', p_message, 'reason', btrim(p_reason)));
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_set_user_status — active | muted | suspended | banned.
-- Suspension/ban revokes live sessions server-side.
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_user_status(
  p_target uuid,
  p_status text,
  p_reason text default ''
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_admin() <> true then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('active','muted','suspended','banned') then
    raise exception 'INVALID_STATUS';
  end if;
  if char_length(coalesce(p_reason,'')) > 500 then raise exception 'INVALID_REASON'; end if;
  if p_target is null then raise exception 'INVALID_TARGET'; end if;
  -- Never allow an admin to demote/alter another admin through this path.
  if exists (select 1 from public.admin_roles ar where ar.user_id = p_target) then
    raise exception 'TARGET_IS_ADMIN';
  end if;

  update public.profiles set status = p_status::public.account_status
   where id = p_target;

  if p_status in ('suspended','banned') then
    delete from auth.sessions where user_id = p_target;
    delete from auth.refresh_tokens where user_id = p_target;
  end if;

  perform private.admin_audit('user.status_changed',
    jsonb_build_object('target', p_target, 'status', p_status, 'reason', btrim(p_reason)));
end;
$$;

-- ============================================================================
-- ROOM MANAGEMENT (built-in rooms)
-- ============================================================================

create or replace function public.admin_upsert_builtin_room(
  p_slug        text,
  p_name        text,
  p_description text default '',
  p_active      boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if private.is_admin() <> true then raise exception 'FORBIDDEN'; end if;

  p_slug := lower(btrim(coalesce(p_slug,'')));
  p_name := btrim(coalesce(p_name,''));
  if p_slug !~ '^[a-z0-9-]{1,60}$' then raise exception 'INVALID_SLUG'; end if;
  if char_length(p_name) < 1 or char_length(p_name) > 60 then raise exception 'INVALID_NAME'; end if;
  if char_length(coalesce(p_description,'')) > 280 then raise exception 'INVALID_DESCRIPTION'; end if;

  insert into public.rooms (slug, name, description, kind, is_active)
  values (p_slug, p_name, coalesce(p_description,''), 'builtin', coalesce(p_active,true))
  on conflict (slug) do update
    set name        = excluded.name,
        description = excluded.description,
        is_active   = excluded.is_active
  returning id into v_id;

  perform private.admin_audit('room.upserted',
    jsonb_build_object('slug', p_slug, 'active', coalesce(p_active,true)));
  return v_id;
end;
$$;

create or replace function public.admin_delete_room(p_room uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_admin() <> true then raise exception 'FORBIDDEN'; end if;
  delete from public.rooms where id = p_room and kind in ('builtin','temporary');
  perform private.admin_audit('room.deleted', jsonb_build_object('room', p_room));
end;
$$;

create or replace function public.admin_list_public_rooms()
returns table (
  id           uuid,
  slug         text,
  name         text,
  description  text,
  kind         public.room_kind,
  is_active    boolean,
  member_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.slug, r.name, r.description, r.kind, r.is_active,
         (select count(*)::bigint from public.room_members m where m.room_id = r.id)
    from public.rooms r
   order by r.kind, r.created_at;
$$;

-- ============================================================================
-- AUDIT LOG READBACK (admins see actions; logs themselves stay sealed tables)
-- ============================================================================
create or replace function public.admin_list_audit_log(p_limit int default 100)
returns table (
  id         bigint,
  event      text,
  details    jsonb,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select l.id, l.event, l.details, l.created_at
    from public.admin_audit_logs l
   order by l.id desc
   limit least(greatest(coalesce(p_limit,100),1),500);
$$;

-- ============================================================================
-- PRIVILEGES — authenticated only (anon locked out); every function still
-- independently re-verifies admin + MFA internally.
-- ============================================================================
revoke execute on function public.admin_list_reports(text,int)                    from public, anon;
revoke execute on function public.admin_get_report_message_context(uuid)          from public, anon;
revoke execute on function public.admin_resolve_report(bigint,text,text)          from public, anon;
revoke execute on function public.admin_remove_public_message(uuid,text)          from public, anon;
revoke execute on function public.admin_set_user_status(uuid,text,text)           from public, anon;
revoke execute on function public.admin_upsert_builtin_room(text,text,text,boolean) from public, anon;
revoke execute on function public.admin_delete_room(uuid)                         from public, anon;
revoke execute on function public.admin_list_public_rooms()                       from public, anon;
revoke execute on function public.admin_list_audit_log(int)                       from public, anon;

grant execute on function public.admin_list_reports(text,int)                     to authenticated;
grant execute on function public.admin_get_report_message_context(uuid)           to authenticated;
grant execute on function public.admin_resolve_report(bigint,text,text)           to authenticated;
grant execute on function public.admin_remove_public_message(uuid,text)           to authenticated;
grant execute on function public.admin_set_user_status(uuid,text,text)            to authenticated;
grant execute on function public.admin_upsert_builtin_room(text,text,text,boolean) to authenticated;
grant execute on function public.admin_delete_room(uuid)                          to authenticated;
grant execute on function public.admin_list_public_rooms()                        to authenticated;
grant execute on function public.admin_list_audit_log(int)                        to authenticated;
