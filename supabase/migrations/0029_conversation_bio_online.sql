-- ============================================================================
-- JUNGLECHAT - 0029_conversation_bio_online.sql
--
-- Surfaces each conversation partners bio + online dot, and each group members
-- bio + online dot. Extends list_my_conversations and get_group_info. These
-- change return shapes, so they are dropped first.
-- ============================================================================

drop function if exists public.list_my_conversations();
create or replace function public.list_my_conversations()
returns table (
  conversation_id uuid,
  partner_id uuid,
  partner_animal text,
  partner_display_id text,
  partner_bio text,
  partner_is_online boolean,
  last_message_at timestamp with time zone,
  unread_count integer
)
language sql stable security definer set search_path = ''
as $$
  select c.id,
         case when c.user_a = auth.uid() then c.user_b else c.user_a end,
         p.animal,
         p.display_animal_id,
         p.bio,
         public.is_user_online(
           case when c.user_a = auth.uid() then c.user_b else c.user_a end),
         c.last_message_at,
         (select count(*)::int
            from public.direct_messages d
           where d.conversation_id = c.id
             and d.sender_id <> auth.uid()
             and d.deleted_at is null
             and d.created_at > coalesce(
                   case when c.user_a = auth.uid()
                        then c.last_read_a else c.last_read_b end,
                   to_timestamp(0)))
    from public.conversations c
    join public.profiles p
      on p.id = (case when c.user_a = auth.uid() then c.user_b else c.user_a end)
   where c.user_a = auth.uid() or c.user_b = auth.uid()
   order by c.last_message_at desc nulls last;
$$;

drop function if exists public.get_group_info(uuid);
create or replace function public.get_group_info(p_group_id uuid)
returns json language plpgsql security definer set search_path = ''
as $$
declare v_result json;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then
    raise exception 'NOT_GROUP_MEMBER';
  end if;
  select json_build_object(
    'id', g.id, 'name', g.name, 'creator_id', g.creator_id,
    'created_at', g.created_at,
    'members', (
      select json_agg(json_build_object(
        'user_id', gm.user_id, 'role', gm.role, 'joined_at', gm.joined_at,
        'animal', p.animal, 'display_animal_id', p.display_animal_id,
        'bio', p.bio, 'is_online', public.is_user_online(gm.user_id)
      ) order by gm.role = 'admin' desc, gm.joined_at asc)
      from public.group_members gm
      join public.profiles p on p.id = gm.user_id
      where gm.group_id = g.id))
  into v_result
  from public.groups g
  where g.id = p_group_id;
  return v_result;
end;
$$;

revoke execute on function public.list_my_conversations() from public, anon;
revoke execute on function public.get_group_info(uuid) from public, anon;
grant execute on function public.list_my_conversations() to authenticated;
grant execute on function public.get_group_info(uuid) to authenticated;