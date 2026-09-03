-- 0308 — open_conversation: collapse 4 round-trips into 1 (item #6 / Phase 5, B8).
--
-- Chat open previously fired is_current_user_admin + is_official_conversation
-- + list_conversations + get_my_profile sequentially on every open — worst-case
-- latency is the SUM of all four on a slow link. This returns the partner
-- identity, online state, official flag, my admin role, unread count, and the
-- partner's typing preference in a single RPC call.

create or replace function public.open_conversation(p_conversation uuid)
returns table (
  partner_id         uuid,
  partner_display_id text,
  partner_animal     text,
  partner_bio        text,
  partner_is_online  boolean,
  is_official        boolean,
  am_admin           boolean,
  unread_count       bigint,
  typing_enabled     boolean,
  my_typing_enabled  boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_partner uuid;
begin
  -- Authorize: I must be a participant of this thread.
  select case when c.user_a = auth.uid() then c.user_b else c.user_a end
    into v_partner
    from public.conversations c
   where c.id = p_conversation
     and (c.user_a = auth.uid() or c.user_b = auth.uid());

  if v_partner is null then
    raise exception 'CONVERSATION_NOT_FOUND';
  end if;

  return query
  select
    v_partner,
    p.display_animal_id,
    p.animal,
    p.bio,
    public.is_user_online(v_partner),
    public.is_official_conversation(p_conversation),
    exists (select 1 from public.admin_roles ar where ar.user_id = auth.uid()),
    (
      select count(*)::bigint
        from public.direct_messages m
       where m.conversation_id = p_conversation
         and m.sender_id <> auth.uid()
         and m.deleted_at is null
         and m.created_at > coalesce(r.last_read_at, timestamptz 'epoch')
    ),
    coalesce(p.typing_indicator_enabled, true),
    (select coalesce(typing_indicator_enabled, true)
       from public.profiles where id = auth.uid()) as my_typing_enabled
  from public.profiles p
  left join private.support_reads r
    on r.conversation_id = p_conversation
   and r.user_id = auth.uid()
  where p.id = v_partner;
end;
$$;

revoke execute on function public.open_conversation(uuid) from public, anon;
grant  execute on function public.open_conversation(uuid) to authenticated;
