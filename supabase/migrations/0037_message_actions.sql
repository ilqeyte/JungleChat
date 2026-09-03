-- ============================================================================
-- JUNGLECHAT - 0037_message_actions.sql
--
-- Message actions: EDIT (with an "edited" mark) within 30 minutes of
-- sending, and DELETE (own messages, tombstone for both sides), for private
-- and group chats. The 30-minute window and sender check are enforced
-- SERVER-SIDE — the client is not trusted (charter).
--
-- Deletion scrubs the content (content = '') so the text is gone from the
-- database too — participants only ever see a "message deleted" tombstone.
-- The content check constraints are relaxed to allow an empty content on
-- rows whose deleted_at is set.
-- ============================================================================

alter table public.direct_messages
  add column if not exists edited_at timestamptz;
alter table public.group_messages
  add column if not exists edited_at timestamptz;

-- ----------------------------------------------------------------------------
-- Relax the content check: empty content is legal ONLY for deleted rows.
-- ----------------------------------------------------------------------------
alter table public.direct_messages drop constraint if exists dm_content_chk;
alter table public.direct_messages
  add constraint dm_content_chk
    check (deleted_at is not null or char_length(content) between 1 and 1000);

do $$
declare c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'public.group_messages'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%char_length(content)%'
   limit 1;
  if c is not null then
    execute format('alter table public.group_messages drop constraint %I', c);
  end if;
end $$;

alter table public.group_messages
  add constraint group_messages_content_chk
    check (deleted_at is not null or char_length(content) between 1 and 1000);

-- ----------------------------------------------------------------------------
-- EDIT — sender only, within 30 minutes, not already deleted. Participants
-- only (private: sender is a participant by construction; group: membership
-- is re-checked so ex-members cannot edit after leaving).
-- ----------------------------------------------------------------------------
create or replace function public.edit_direct_message(p_message uuid, p_content text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.ensure_active_account();
  perform private.rate_limit('dm_edit', coalesce(auth.uid()::text, private.client_ip()), 60, interval '10 minutes');

  p_content := btrim(coalesce(p_content, ''));
  if char_length(p_content) < 1 or char_length(p_content) > 1000 then
    raise exception 'INVALID_MESSAGE';
  end if;

  update public.direct_messages m
     set content = p_content,
         edited_at = now()
   where m.id = p_message
     and m.sender_id = auth.uid()
     and m.deleted_at is null
     and m.created_at > now() - interval '30 minutes';

  if not found then
    raise exception 'MESSAGE_NOT_EDITABLE';
  end if;
end;
$$;

create or replace function public.edit_group_message(p_message uuid, p_content text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.ensure_active_account();
  perform private.rate_limit('group_msg_edit', coalesce(auth.uid()::text, private.client_ip()), 60, interval '10 minutes');

  p_content := btrim(coalesce(p_content, ''));
  if char_length(p_content) < 1 or char_length(p_content) > 1000 then
    raise exception 'INVALID_MESSAGE';
  end if;

  update public.group_messages m
     set content = p_content,
         edited_at = now()
   where m.id = p_message
     and m.sender_id = auth.uid()
     and m.deleted_at is null
     and m.created_at > now() - interval '30 minutes'
     and exists (
       select 1 from public.group_members gm
        where gm.group_id = m.group_id
          and gm.user_id = auth.uid());

  if not found then
    raise exception 'MESSAGE_NOT_EDITABLE';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- DELETE — sender only, any age (own message), tombstone + content scrubbed.
-- ----------------------------------------------------------------------------
create or replace function public.delete_direct_message(p_message uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.ensure_active_account();

  update public.direct_messages m
     set content = '',
         deleted_at = now(),
         deleted_by = auth.uid()
   where m.id = p_message
     and m.sender_id = auth.uid()
     and m.deleted_at is null;

  if not found then
    raise exception 'MESSAGE_NOT_DELETABLE';
  end if;
end;
$$;

create or replace function public.delete_group_message(p_message uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.ensure_active_account();

  update public.group_messages m
     set content = '',
         deleted_at = now(),
         deleted_by = auth.uid()
   where m.id = p_message
     and m.sender_id = auth.uid()
     and m.deleted_at is null
     and exists (
       select 1 from public.group_members gm
        where gm.group_id = m.group_id
          and gm.user_id = auth.uid());

  if not found then
    raise exception 'MESSAGE_NOT_DELETABLE';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- Privileges — authenticated only.
-- ----------------------------------------------------------------------------
revoke execute on function public.edit_direct_message(uuid, text)   from public, anon;
revoke execute on function public.delete_direct_message(uuid)       from public, anon;
revoke execute on function public.edit_group_message(uuid, text)    from public, anon;
revoke execute on function public.delete_group_message(uuid)        from public, anon;

grant execute on function public.edit_direct_message(uuid, text)   to authenticated;
grant execute on function public.delete_direct_message(uuid)       to authenticated;
grant execute on function public.edit_group_message(uuid, text)    to authenticated;
grant execute on function public.delete_group_message(uuid)        to authenticated;
