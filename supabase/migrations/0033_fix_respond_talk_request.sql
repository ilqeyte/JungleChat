-- ============================================================================
-- JUNGLECHAT — 0033_fix_respond_talk_request.sql
--
-- Accept on talk requests failed with a generic client error since 0031:
-- the rewritten UPDATE assigned a text CASE expression to talk_requests
--.status, which is the enum public.request_status — Postgres rejects the
-- assignment (42804) at runtime. The original 0004 body cast it; the cast
-- was dropped in the rewrite. Restored. Everything else unchanged from 0031.
-- ============================================================================

create or replace function public.respond_talk_request(p_request uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   uuid := auth.uid();
  v_req  public.talk_requests%rowtype;
  v_conv uuid;
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
     set status = (case when p_accept then 'accepted' else 'denied' end)::public.request_status,
         responded_at = now()
   where id = v_req.id;

  if p_accept then
    insert into public.conversations (user_a, user_b)
    values (least(v_req.requester_id, v_req.target_id),
            greatest(v_req.requester_id, v_req.target_id))
    on conflict (user_a, user_b) do nothing
    returning id into v_conv;

    if v_conv is null then
      select c.id into v_conv
        from public.conversations c
       where c.user_a = least(v_req.requester_id, v_req.target_id)
         and c.user_b = greatest(v_req.requester_id, v_req.target_id);
    end if;

    perform private.notify(v_req.requester_id, 'talk_accepted',
      jsonb_build_object('conversation_id', v_conv));
  end if;
end;
$$;

revoke all on function public.respond_talk_request(uuid, boolean) from public, anon;
grant execute on function public.respond_talk_request(uuid, boolean) to authenticated;
