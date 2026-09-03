-- ============================================================================
-- JUNGLECHAT — 0004_social_functions.sql
--
-- Talk requests (state machine), blocking, random talk matching, reporting.
-- Every entry point: authenticated only, rate limited, state-checked here.
-- Notifications are written ONLY through private.notify(), which enforces a
-- strict whitelist of privacy-safe templates (no content, no Animal IDs).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- private.notify() — the ONLY notification writer. Whitelisted kinds carry a
-- fixed, non-identifying surface. Payload holds routing ids only.
-- ----------------------------------------------------------------------------
create or replace function private.notify(p_user uuid, p_kind text, p_payload jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_kind not in ('new_message', 'talk_request', 'talk_accepted', 'inactivity_warning') then
    raise exception 'NOTIFICATION_KIND_FORBIDDEN';
  end if;
  insert into public.notifications (user_id, kind, payload)
  values (p_user, p_kind, p_payload);
end;
$$;

revoke execute on function private.notify(uuid,text,jsonb) from public, anon, authenticated;

-- ============================================================================
-- TALK REQUESTS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- send_talk_request — discovery gate enforced HERE, not in Flutter.
-- ----------------------------------------------------------------------------
create or replace function public.send_talk_request(p_target uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me       uuid := auth.uid();
  v_existing uuid;
  v_id       uuid;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('talk_request', coalesce(v_me::text, private.client_ip()), 15, interval '1 hour');
  perform private.touch_activity();

  if p_target is null or p_target = v_me then
    raise exception 'INVALID_TARGET';
  end if;

  -- Shadow mode / status / deletion must permit discovery right now.
  if not private.can_discover(p_target) then
    raise exception 'TARGET_UNAVAILABLE';   -- generic: same for shadow/ban/nonexistent
  end if;

  -- No new request if any non-terminal request already exists between us.
  select id into v_existing
    from public.talk_requests
   where ((requester_id = v_me and target_id = p_target)
       or (requester_id = p_target and target_id = v_me))
     and status in ('pending')
   limit 1;
  if v_existing is not null then
    return v_existing;   -- idempotent: reuse existing pending request
  end if;

  insert into public.talk_requests (requester_id, target_id)
  values (v_me, p_target)
  returning id into v_id;

  perform private.notify(p_target, 'talk_request', jsonb_build_object('request_id', v_id));
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- respond_talk_request — only the target, only while pending/unexpired.
-- Acceptance creates the private conversation (ordered pair).
-- ----------------------------------------------------------------------------
create or replace function public.respond_talk_request(p_request uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   uuid := auth.uid();
  v_req  public.talk_requests%rowtype;
begin
  perform private.ensure_active_account();
  perform private.client_rate_limit('respond_request', 60, interval '10 minutes');
  perform private.touch_activity();

  select * into v_req
    from public.talk_requests
   where id = p_request
     and target_id = v_me
   for update;

  if v_req.id is null then
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  if v_req.status <> 'pending' or v_req.expires_at < now() then
    raise exception 'REQUEST_NOT_ACTIVE';
  end if;

  update public.talk_requests
     set status = case when p_accept then 'accepted' else 'denied' end,
         responded_at = now()
   where id = v_req.id;

  if p_accept then
    insert into public.conversations (user_a, user_b)
    values (least(v_req.requester_id, v_req.target_id),
            greatest(v_req.requester_id, v_req.target_id))
    on conflict (user_a, user_b) do nothing;

    perform private.notify(v_req.requester_id, 'talk_accepted', '{}');
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- cancel_talk_request — requester may withdraw while pending.
-- ----------------------------------------------------------------------------
create or replace function public.cancel_talk_request(p_request uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.client_rate_limit('cancel_request', 30, interval '10 minutes');

  update public.talk_requests
     set status = 'cancelled', responded_at = now()
   where id = p_request
     and requester_id = auth.uid()
     and status = 'pending';
  -- No exception when absent: cancellation is best-effort by design.
end;
$$;

-- ----------------------------------------------------------------------------
-- list_talk_requests(kind) — incoming (target) or outgoing (requester) pending.
-- ----------------------------------------------------------------------------
create or replace function public.list_talk_requests(p_kind text default 'incoming')
returns table (
  request_id        uuid,
  other_display_id  text,
  other_animal      text,
  created_at        timestamptz,
  expires_at        timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select tr.id,
         p.display_animal_id,
         p.animal,
         tr.created_at,
         tr.expires_at
    from public.talk_requests tr
    join public.profiles p
      on p.id = case when p_kind = 'incoming' then tr.requester_id else tr.target_id end
   where (p_kind = 'incoming' and tr.target_id = auth.uid())
      or (p_kind = 'outgoing' and tr.requester_id = auth.uid())
   order by tr.created_at desc
   limit 100;
$$;

-- ============================================================================
-- BLOCKING — server-enforced across every social surface.
-- ============================================================================

create or replace function public.block_animal(p_target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
begin
  perform private.ensure_active_account();
  perform private.rate_limit('block_action', coalesce(v_me::text, private.client_ip()), 40, interval '1 hour');

  if p_target is null or p_target = v_me then
    raise exception 'INVALID_TARGET';
  end if;

  insert into public.blocks (blocker_id, blocked_id) values (v_me, p_target)
  on conflict do nothing;

  -- Kill any live request lines between the pair immediately.
  update public.talk_requests
     set status = 'blocked', responded_at = now()
   where status in ('pending')
     and ((requester_id = v_me and target_id = p_target)
       or (requester_id = p_target and target_id = v_me));
end;
$$;

create or replace function public.unblock_animal(p_target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.ensure_active_account();
  perform private.rate_limit('unblock_action', coalesce(auth.uid()::text, private.client_ip()), 40, interval '1 hour');

  delete from public.blocks
   where blocker_id = auth.uid() and blocked_id = p_target;
end;
$$;

create or replace function public.list_my_blocks()
returns table (
  user_id           uuid,
  animal            text,
  display_animal_id text
)
language sql
stable
security definer
set search_path = ''
as $$
  select b.blocked_id, p.animal, p.display_animal_id
    from public.blocks b
    join public.profiles p on p.id = b.blocked_id
   where b.blocker_id = auth.uid()
   order by b.created_at desc;
$$;

-- ============================================================================
-- RANDOM TALK — returns ONE eligible candidate card. Connection still happens
-- through an explicit talk request (never automatic private access).
-- ============================================================================
create or replace function public.random_talk_candidate()
returns table (
  id                uuid,
  animal            text,
  display_animal_id text,
  open_to_talk      boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.animal, t.display_animal_id, t.open_to_talk
    from (
      select *
        from public.profiles p
       where p.id <> auth.uid()
         and p.open_to_talk
         and p.random_talk_enabled
         and p.deleted_at is null
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

-- ============================================================================
-- REPORTING — context attached SERVER-side; reporter identity stays internal.
-- ============================================================================

-- Auto-fill human_ref like R-1842 from the bigint identity.
create or replace function public.reports_human_ref()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.human_ref := 'R-' || new.id::text;
  return new;
end;
$$;

create trigger reports_human_ref
  before insert on public.reports
  for each row
  execute function public.reports_human_ref();

create or replace function public.submit_report(
  p_type            text,
  p_body            text,
  p_target_user     uuid default null,
  p_target_message  uuid default null,
  p_target_room     uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_msg   public.messages%rowtype;
  v_ref   text;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('report_submit', coalesce(auth.uid()::text, private.client_ip()), 8, interval '1 hour');

  if p_type not in ('user_report','message_report','room_report','bug_report','error_report','other') then
    raise exception 'INVALID_REPORT_TYPE';
  end if;
  p_body := btrim(coalesce(p_body, ''));
  if char_length(p_body) < 1 or char_length(p_body) > 2000 then
    raise exception 'INVALID_REPORT_BODY';
  end if;

  -- When reporting a message, attach authoritative context ourselves so the
  -- reporter never has to supply (or fake) ids.
  if p_target_message is not null then
    select * into v_msg from public.messages where id = p_target_message;
    if v_msg.id is not null then
      p_target_user := v_msg.sender_id;
      p_target_room := v_msg.room_id;
    end if;
  end if;

  insert into public.reports (reporter_id, type, target_user_id, target_message_id, target_room_id, body)
  values (auth.uid(), p_type::public.report_type, p_target_user, p_target_message, p_target_room, p_body)
  returning human_ref into v_ref;

  return v_ref;
end;
$$;

-- ============================================================================
-- MUTES (UX only — never a security control)
-- ============================================================================
create or replace function public.set_mute(p_scope text, p_scope_id text, p_muted boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_scope not in ('conversation','room') then
    raise exception 'INVALID_MUTE_SCOPE';
  end if;
  if p_muted then
    insert into public.mutes (user_id, scope, scope_id)
    values (auth.uid(), p_scope::public.mute_scope, left(btrim(p_scope_id), 64))
    on conflict do nothing;
  else
    delete from public.mutes
     where user_id = auth.uid()
       and scope = p_scope::public.mute_scope
       and scope_id = left(btrim(p_scope_id), 64);
  end if;
end;
$$;

create or replace function public.list_my_mutes()
returns table (scope public.mute_scope, scope_id text)
language sql
stable
security definer
set search_path = ''
as $$
  select scope, scope_id from public.mutes where user_id = auth.uid();
$$;

-- ============================================================================
-- PRIVILEGES
-- ============================================================================
revoke execute on function public.send_talk_request(uuid)                      from public, anon;
revoke execute on function public.respond_talk_request(uuid,boolean)          from public, anon;
revoke execute on function public.cancel_talk_request(uuid)                   from public, anon;
revoke execute on function public.list_talk_requests(text)                    from public, anon;
revoke execute on function public.block_animal(uuid)                          from public, anon;
revoke execute on function public.unblock_animal(uuid)                        from public, anon;
revoke execute on function public.list_my_blocks()                            from public, anon;
revoke execute on function public.random_talk_candidate()                     from public, anon;
revoke execute on function public.submit_report(text,text,uuid,uuid,uuid)     from public, anon;
revoke execute on function public.set_mute(text,text,boolean)                 from public, anon;
revoke execute on function public.list_my_mutes()                             from public, anon;

grant execute on function public.send_talk_request(uuid)                      to authenticated;
grant execute on function public.respond_talk_request(uuid,boolean)          to authenticated;
grant execute on function public.cancel_talk_request(uuid)                   to authenticated;
grant execute on function public.list_talk_requests(text)                    to authenticated;
grant execute on function public.block_animal(uuid)                          to authenticated;
grant execute on function public.unblock_animal(uuid)                        to authenticated;
grant execute on function public.list_my_blocks()                            to authenticated;
grant execute on function public.random_talk_candidate()                     to authenticated;
grant execute on function public.submit_report(text,text,uuid,uuid,uuid)     to authenticated;
grant execute on function public.set_mute(text,text,boolean)                 to authenticated;
grant execute on function public.list_my_mutes()                             to authenticated;
