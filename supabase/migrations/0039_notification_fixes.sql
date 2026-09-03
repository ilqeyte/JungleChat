-- ============================================================================
-- JUNGLECHAT — 0039_notification_fixes.sql
--
-- Two live regressions + one privilege gap introduced by 0038, all confirmed
-- by impersonated probes against production (rolled-back transactions):
--
--   BUG 1: private.notify's kind whitelist (rewritten in 0038) dropped
--     'official_message', so admin_send_support_message (0035) — Adam's
--     dashboard Messages feature — failed on EVERY send with
--     NOTIFICATION_KIND_FORBIDDEN. Probe result: "FAILED:
--     NOTIFICATION_KIND_FORBIDDEN".
--
--   BUG 2: the 0038 rewrite of send_group_message (reply support) dropped
--     the 0031 per-member fan-out of kind 'group_message', so group
--     messages stopped producing ANY notification (in-app feed + push).
--     Probe result: "members=1 fanout=0 CONFIRMED-NO-FANOUT".
--
--   BUG 3 (found in the same audit): admin_list_audit_log and
--     admin_list_reports were SECURITY DEFINER + executable by every
--     authenticated user with NO in-body admin gate — any user could read
--     the entire audit trail and all reports. admin_list_support_conversations
--     was only implicitly gated by an admin_roles JOIN. All three now raise
--     NOT_ADMIN for non-admins, like every other admin RPC.
--
-- Fixes (minimal, no behavior changes beyond the bugs above):
--   1. private.notify whitelist gains 'official_message' and
--      'group_message' (both are legitimate, client-handled kinds).
--   2. send_group_message keeps the 0038 reply validation and regains:
--        - the per-member 'group_message' fan-out (payload {group_id}
--          ONLY — charter rule 8: no names, no previews, no Animal IDs),
--        - private.ensure_active_account() (suspended users cannot send),
--        - private.touch_activity() (charter rule 10: sending a message is
--          a qualifying deliberate action, same as send_direct_message).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. private.notify — whitelist extended.
-- ----------------------------------------------------------------------------
create or replace function private.notify(p_user uuid, p_kind text, p_payload jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_kind not in ('new_message', 'talk_request', 'talk_accepted',
                    'inactivity_warning', 'group_added',
                    'official_message', 'group_message') then
    raise exception 'NOTIFICATION_KIND_FORBIDDEN';
  end if;
  insert into public.notifications (user_id, kind, payload)
  values (p_user, p_kind, p_payload);
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. send_group_message — fan-out + account guard + activity touch restored.
-- ----------------------------------------------------------------------------
create or replace function public.send_group_message(
  p_group_id uuid,
  p_content  text,
  p_reply_to uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_msg_id uuid;
  v_trimmed text;
begin
  perform private.ensure_active_account();
  perform private.touch_activity();

  v_trimmed := btrim(coalesce(p_content, ''));

  -- Validate content
  if char_length(v_trimmed) < 1 or char_length(v_trimmed) > 1000 then
    raise exception 'INVALID_MESSAGE_LENGTH';
  end if;

  -- Verify membership
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_MEMBER';
  end if;

  -- Rate limit: 60 messages per 10 minutes per user per group
  perform private.rate_limit('group_msg', auth.uid()::text || ':' || p_group_id::text, 60, interval '10 minutes');

  -- Reply target: same group, exists, not deleted.
  if p_reply_to is not null and not exists (
    select 1 from public.group_messages r
     where r.id = p_reply_to
       and r.group_id = p_group_id
       and r.deleted_at is null
  ) then
    raise exception 'INVALID_REPLY';
  end if;

  -- Insert message
  insert into public.group_messages (group_id, sender_id, content, reply_to_id)
  values (p_group_id, auth.uid(), v_trimmed, p_reply_to)
  returning id into v_msg_id;

  -- Update group timestamp
  update public.groups set updated_at = now() where id = p_group_id;

  -- Fan-out: one row per other member. Payload carries the group UUID ONLY
  -- (routing key, never rendered) — charter rule 8. Restores the 0031
  -- behavior the 0038 rewrite dropped.
  insert into public.notifications (user_id, kind, payload)
  select gm.user_id, 'group_message', jsonb_build_object('group_id', p_group_id)
    from public.group_members gm
   where gm.group_id = p_group_id
     and gm.user_id <> auth.uid();

  return v_msg_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. admin_send_support_message gains an optional, validated reply target so
--    Adam's swipe-to-reply quotes work in official threads (same INVALID_REPLY
--    rules as the user send path). The old 2-arg signature is dropped so no
--    call can bypass reply validation.
-- ----------------------------------------------------------------------------
create or replace function public.admin_send_support_message(
  p_conversation uuid,
  p_content text,
  p_reply_to uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_other uuid;
begin
  if not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  perform private.rate_limit('dm_send', auth.uid()::text, 60, interval '10 minutes');
  perform private.touch_activity();

  p_content := btrim(coalesce(p_content, ''));
  if char_length(p_content) < 1 or char_length(p_content) > 1000 then
    raise exception 'INVALID_MESSAGE';
  end if;

  select case when c.user_a = auth.uid() then c.user_b else c.user_a end
    into v_other
    from public.conversations c
   where c.id = p_conversation
     and (c.user_a = auth.uid() or c.user_b = auth.uid());

  if v_other is null then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  -- Reply target: same thread, exists, not deleted (same rule as users).
  if p_reply_to is not null and not exists (
    select 1 from public.direct_messages r
     where r.id = p_reply_to
       and r.conversation_id = p_conversation
       and r.deleted_at is null
  ) then
    raise exception 'INVALID_REPLY';
  end if;

  insert into public.direct_messages (conversation_id, sender_id, content, reply_to_id)
  values (p_conversation, auth.uid(), p_content, p_reply_to)
  returning id into v_id;

  update public.conversations
     set last_message_at = now()
   where id = p_conversation;

  -- Official sender: distinct kind so the client + push worker can label
  -- it "Adam sent you a message." Payload carries the conversation UUID
  -- only (routing key, never rendered — charter rule 8).
  perform private.notify(v_other, 'official_message',
    jsonb_build_object('conversation_id', p_conversation));

  perform private.admin_audit('support_chat.message_sent',
    jsonb_build_object('conversation', p_conversation, 'to', v_other));
  return v_id;
end;
$$;

drop function if exists public.admin_send_support_message(uuid, text);

-- ----------------------------------------------------------------------------
-- 4. Admin READ functions gain explicit gates (charter: every admin call is
--    verified server-side). Found open during the full functional audit:
--    admin_list_audit_log and admin_list_reports were SECURITY DEFINER and
--    executable by ANY authenticated user — every user could read the whole
--    audit trail and all reports. admin_list_support_conversations was only
--    implicitly gated by an admin_roles JOIN; it now fails loudly instead of
--    silently returning rows.
-- ----------------------------------------------------------------------------
create or replace function public.admin_list_audit_log(p_limit integer default 100)
returns table(id bigint, event text, details jsonb, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_roles ar where ar.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;
  return query
  select l.id, l.event, l.details, l.created_at
    from public.admin_audit_logs l
   order by l.id desc
   limit least(greatest(coalesce(p_limit,100),1),500);
end;
$$;

drop function if exists public.admin_list_reports(text, integer);
create or replace function public.admin_list_reports(p_status text default 'open', p_limit integer default 50)
returns table(id bigint, human_ref text, type public.report_type, status public.report_status,
               body text, created_at timestamptz, reported_animal text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_roles ar where ar.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;
  return query
  select rp.id, rp.human_ref, rp.type, rp.status, rp.body, rp.created_at,
         tp.display_animal_id
    from public.reports rp
    left join public.profiles tp on tp.id = rp.target_user_id
   where rp.status = coalesce(p_status::public.report_status, rp.status)
   order by rp.created_at desc
   limit least(greatest(coalesce(p_limit,50),1),200);
end;
$$;

create or replace function public.admin_list_support_conversations()
returns table(conversation_id uuid, partner_id uuid, partner_display_id text,
               partner_animal text, unread_count bigint, last_message_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_roles ar where ar.user_id = auth.uid()) then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;
  return query
  select
    c.id,
    case when c.user_a = auth.uid() then c.user_b else c.user_a end as partner_id,
    p.display_animal_id,
    p.animal,
    (
      select count(*)::bigint from public.direct_messages m
       where m.conversation_id = c.id
         and m.sender_id <> auth.uid()
         and m.deleted_at is null
         and m.created_at > coalesce(r.last_read_at, timestamptz 'epoch')
    ) as unread_count,
    c.last_message_at
  from public.conversations c
  join public.profiles p
    on p.id = (case when c.user_a = auth.uid() then c.user_b else c.user_a end)
  left join private.support_reads r
    on r.conversation_id = c.id and r.user_id = auth.uid()
  where (c.user_a = auth.uid() or c.user_b = auth.uid())
  order by c.last_message_at desc nulls last;
end;
$$;
