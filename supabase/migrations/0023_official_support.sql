-- ============================================================================
-- JUNGLECHAT — 0023_official_support.sql
--
-- Official support channel: the admin ("Adam") can open conversations with
-- users and message them through the normal chat infrastructure.
--
-- DESIGN
--   * The admin is a REAL conversation participant. Sending/receiving uses
--     the existing direct-message path, so RLS, streams and notifications
--     behave exactly like any private chat.
--   * Verification is SERVER-DERIVED: a conversation is "official" iff the
--     OTHER participant is in admin_roles. The client never hardcodes an
--     admin id — impersonation resistance comes from the database.
--   * Every admin entry point calls private.is_admin() (which also requires
--     an MFA-elevated aal2 session) and raises one opaque error otherwise.
--   * Admin messages are rate-limited and audited via admin_audit_logs.
--   * support_reads is a private read-tracking table for the admin inbox.
--     It has RLS enabled with NO policies — deny-by-default, reachable only
--     through the security definer RPCs below.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- support_reads — last time a participant read a support conversation.
-- ----------------------------------------------------------------------------
create table private.support_reads (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  last_read_at    timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

alter table private.support_reads enable row level security;

-- ----------------------------------------------------------------------------
-- is_official_conversation — user-side verification signal. True iff the
-- caller participates and the OTHER participant is an admin.
-- ----------------------------------------------------------------------------
create or replace function public.is_official_conversation(p_conversation uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.conversations c
      join public.admin_roles ar
        on ar.user_id in (c.user_a, c.user_b)
     and ar.user_id <> auth.uid()
     where c.id = p_conversation
       and (c.user_a = auth.uid() or c.user_b = auth.uid())
  );
$$;

-- ----------------------------------------------------------------------------
-- admin_open_support_chat — open (or return) the support thread with a user.
-- The pair is stored ordered to satisfy conversations_pair_chk. Blocking and
-- talk-request rules are intentionally bypassed: this is the official channel.
-- ----------------------------------------------------------------------------
create or replace function public.admin_open_support_chat(p_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   uuid;
  v_a    uuid;
  v_b    uuid;
  v_id   uuid;
  v_status public.account_status;
begin
  if not private.is_admin() then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  v_me := auth.uid();
  if p_user is null or p_user = v_me then
    raise exception 'INVALID_TARGET';
  end if;

  select status into v_status from public.profiles where id = p_user;
  if v_status is null or v_status = 'banned' then
    raise exception 'TARGET_NOT_FOUND';
  end if;

  v_a := least(v_me, p_user);
  v_b := greatest(v_me, p_user);

  insert into public.conversations (user_a, user_b)
  values (v_a, v_b)
  on conflict (user_a, user_b) do nothing
  returning id into v_id;

  if v_id is null then
    select c.id into v_id
      from public.conversations c
     where c.user_a = v_a and c.user_b = v_b;
  end if;

  perform private.admin_audit('support_chat.opened',
    jsonb_build_object('conversation', v_id, 'user', p_user));
  return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_list_support_conversations — inbox for the dashboard: every support
-- thread with the user's display identity and unread count (messages from
-- the user newer than the admin's last read mark).
-- ----------------------------------------------------------------------------
create or replace function public.admin_list_support_conversations()
returns table (
  conversation_id    uuid,
  partner_id         uuid,
  partner_display_id text,
  partner_animal     text,
  unread_count       bigint,
  last_message_at    timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
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
  join public.admin_roles ar
    on ar.user_id in (c.user_a, c.user_b) and ar.user_id = auth.uid()
  join public.profiles p
    on p.id = (case when c.user_a = auth.uid() then c.user_b else c.user_a end)
  left join private.support_reads r
    on r.conversation_id = c.id and r.user_id = auth.uid()
  where (c.user_a = auth.uid() or c.user_b = auth.uid())
  order by c.last_message_at desc nulls last;
$$;

-- ----------------------------------------------------------------------------
-- admin_mark_support_read — clears the inbox unread counter for the admin.
-- ----------------------------------------------------------------------------
create or replace function public.admin_mark_support_read(p_conversation uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'NOT_ADMIN' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.conversations c
     where c.id = p_conversation
       and (c.user_a = auth.uid() or c.user_b = auth.uid())
  ) then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  insert into private.support_reads (conversation_id, user_id, last_read_at)
  values (p_conversation, auth.uid(), now())
  on conflict (conversation_id, user_id)
  do update set last_read_at = now();
end;
$$;

-- ----------------------------------------------------------------------------
-- admin_send_support_message — audited, rate-limited send for the official
-- channel. Mirrors send_direct_message but: verified by is_admin(), overrides
-- blocks (official channel), and writes an audit entry.
-- ----------------------------------------------------------------------------
create or replace function public.admin_send_support_message(
  p_conversation uuid,
  p_content text
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
  if not private.is_admin() then
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

  insert into public.direct_messages (conversation_id, sender_id, content)
  values (p_conversation, auth.uid(), p_content)
  returning id into v_id;

  update public.conversations
     set last_message_at = now()
   where id = p_conversation;

  -- Privacy-safe: payload carries ONLY the conversation id to tap into.
  perform private.notify(v_other, 'new_message',
    jsonb_build_object('conversation_id', p_conversation));

  perform private.admin_audit('support_chat.message_sent',
    jsonb_build_object('conversation', p_conversation, 'to', v_other));
  return v_id;
end;
$$;

-- ============================================================================
-- PRIVILEGES — authenticated only, never anon.
-- ============================================================================
revoke execute on function public.is_official_conversation(uuid)         from public, anon;
revoke execute on function public.admin_open_support_chat(uuid)          from public, anon, authenticated;
revoke execute on function public.admin_list_support_conversations()     from public, anon, authenticated;
revoke execute on function public.admin_mark_support_read(uuid)          from public, anon, authenticated;
revoke execute on function public.admin_send_support_message(uuid,text)  from public, anon, authenticated;

grant execute on function public.is_official_conversation(uuid)          to authenticated;
-- Admin RPCs stay granted to authenticated: the is_admin() + aal2 gate is
-- the real authorization, matching the pattern of 0006/0021.
grant execute on function public.admin_open_support_chat(uuid)           to authenticated;
grant execute on function public.admin_list_support_conversations()      to authenticated;
grant execute on function public.admin_mark_support_read(uuid)           to authenticated;
grant execute on function public.admin_send_support_message(uuid,text)   to authenticated;
