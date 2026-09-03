-- ============================================================================
-- JUNGLECHAT — 0313_client_functions.sql
--
-- Clean reimplementation of the client-facing functions previously captured
-- in the legacy 0027 file. Only functions the app actually calls are kept:
--   * list_my_conversations()  — chat list with partner + unread count
-- The other legacy functions (change_my_animal, mark_conversation_read,
-- set_typing, upsert_push_token, service_set_login_password) are either
-- redefined elsewhere, dropped, or superseded by the 0310 password model.
-- ============================================================================

-- Drop the legacy 8-column shape (defined in 0029) so we can replace the
-- return type. The client is rewritten to consume this leaner shape.
drop function if exists public.list_my_conversations();

create or replace function public.list_my_conversations()
returns table (
  conversation_id     uuid,
  partner_id          uuid,
  partner_animal      text,
  partner_display_id  text,
  last_message_at     timestamptz,
  unread_count        integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
         case when c.user_a = auth.uid() then c.user_b else c.user_a end,
         p.animal,
         p.display_animal_id,
         c.last_message_at,
         (select count(*)::int
            from public.direct_messages d
           where d.conversation_id = c.id
             and d.sender_id <> auth.uid()
             and d.deleted_at is null
             and d.created_at > coalesce(
                   case when c.user_a = auth.uid() then c.last_read_a else c.last_read_b end,
                   to_timestamp(0)))
    from public.conversations c
    join public.profiles p
      on p.id = (case when c.user_a = auth.uid() then c.user_b else c.user_a end)
   where c.user_a = auth.uid() or c.user_b = auth.uid()
   order by c.last_message_at desc nulls last;
$$;

revoke execute on function public.list_my_conversations() from public, anon;
grant execute on function public.list_my_conversations() to authenticated;
