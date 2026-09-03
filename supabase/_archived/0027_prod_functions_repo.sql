-- ============================================================================
-- JUNGLECHAT - 0027_prod_functions_repo.sql
--
-- Reproduces six supported client-facing functions that existed only on prod
-- (deployed directly, never committed). Captured verbatim from prod so the repo
-- matches reality and a fresh DB can reproduce them. Admin-list/suspend are
-- covered by the HARDENED versions in 0026.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.change_my_animal(p_new_animal text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me      uuid := auth.uid();
  v_new     text := initcap(btrim(coalesce(p_new_animal, '')));
  v_old     text;
  v_num     int;
  v_display text;
begin
  perform private.ensure_active_account();
  perform private.rate_limit('change_animal', v_me::text, 3, interval '7 days');

  if not exists (select 1 from private.animal_catalog where animal = v_new) then
    raise exception 'INVALID_ANIMAL';
  end if;

  select animal, animal_number into v_old, v_num
    from public.profiles where id = v_me;
  if v_old is null then
    raise exception 'ACCOUNT_NOT_FOUND';
  end if;
  if v_old = v_new then
    return upper(v_new) || '-' || v_num::text;
  end if;

  perform pg_advisory_xact_lock(hashtext('junglechat|alloc|' || v_new));

  -- RELEASE FIRST: animal_id has unique(user_id) - the account may hold
  -- only one slot at a time. Transaction makes the swap atomic.
  update public.animal_id
     set user_id = null, released_at = now()
   where animal = v_old and user_id = v_me;

  -- Claim the new species slot (released first, else next number).
  update public.animal_id a
     set user_id = v_me, allocated_at = now(), released_at = null
   where a.animal = v_new
     and a.user_id is null
     and a.released_at is not null
     and a.number = (select min(a2.number) from public.animal_id a2
                      where a2.animal = v_new and a2.user_id is null and a2.released_at is not null)
   returning a.number into v_num;

  if v_num is null then
    select coalesce(max(a.number), 0) + 1 into v_num
      from public.animal_id a where a.animal = v_new;
    insert into public.animal_id (animal, number, user_id)
    values (v_new, v_num, v_me);
  end if;

  v_display := upper(v_new) || '-' || v_num::text;

  update public.profiles
     set animal = v_new, animal_number = v_num, display_animal_id = v_display
   where id = v_me;

  return v_display;
end;
$function$

CREATE OR REPLACE FUNCTION public.list_my_conversations()
 RETURNS TABLE(conversation_id uuid, partner_id uuid, partner_animal text, partner_display_id text, last_message_at timestamp with time zone, unread_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
                   case when c.user_a = auth.uid()
                        then c.last_read_a else c.last_read_b end,
                   to_timestamp(0)))
    from public.conversations c
    join public.profiles p
      on p.id = (case when c.user_a = auth.uid() then c.user_b else c.user_a end)
   where c.user_a = auth.uid() or c.user_b = auth.uid()
   order by c.last_message_at desc nulls last;
$function$

CREATE OR REPLACE FUNCTION public.mark_conversation_read(p_conversation uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
begin
  update public.conversations c
     set last_read_a = case when c.user_a = v_me then now() else c.last_read_a end,
         last_read_b = case when c.user_b = v_me then now() else c.last_read_b end
   where c.id = p_conversation
     and (c.user_a = v_me or c.user_b = v_me);

  update public.notifications
     set read_at = now()
   where user_id = v_me
     and kind = 'new_message'
     and read_at is null
     and payload ->> 'conversation_id' = p_conversation::text;
end;
$function$

CREATE OR REPLACE FUNCTION public.service_set_login_password(p_current_secret text, p_new_password text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid            uuid := auth.uid();
  v_stored         text;
  v_cred_hash      text;
  v_matches        boolean := false;
begin
  if v_uid is null then
    raise exception 'FORBIDDEN';
  end if;

  perform private.rate_limit('password_set', v_uid::text, 10, interval '1 hour');

  p_new_password := coalesce(p_new_password, '');
  if char_length(p_new_password) < 8 or char_length(p_new_password) > 72 then
    raise exception 'INVALID_PASSWORD';
  end if;
  if p_current_secret is null or btrim(p_current_secret) = '' then
    raise exception 'INVALID_CURRENT_SECRET';
  end if;

  select encrypted_password into v_stored from auth.users where id = v_uid;
  if v_stored is null then
    raise exception 'ACCOUNT_NOT_FOUND';
  end if;

  select credential_hash into v_cred_hash
    from public.recovery_credentials where user_id = v_uid;

  -- Current secret may be the login password OR the recovery credential.
  if v_stored = extensions.crypt(p_current_secret, v_stored) then
    v_matches := true;
    -- auth.users still holds the CREDENTIAL (password never set): preserve it.
    if v_cred_hash is null then
      insert into public.recovery_credentials (user_id, credential_hash)
      values (v_uid, v_stored)
      on conflict (user_id) do nothing;
    end if;
  elsif v_cred_hash is not null
        and v_cred_hash = extensions.crypt(p_current_secret, v_cred_hash) then
    v_matches := true;
  end if;

  if not v_matches then
    insert into public.security_events (event, actor_hint)
    values ('password_set.failed', left(private.subject_key(v_uid::text), 16));
    raise exception 'CURRENT_SECRET_WRONG';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf', 10))
   where id = v_uid;
end;
$function$

CREATE OR REPLACE FUNCTION public.set_typing(p_conversation uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := auth.uid();
begin
  perform private.ensure_active_account();
  perform private.rate_limit('typing', v_me::text, 120, interval '1 hour');

  update public.conversations c
     set typing_a_until = case when c.user_a = v_me then now() + interval '4 seconds' else c.typing_a_until end,
         typing_b_until = case when c.user_b = v_me then now() + interval '4 seconds' else c.typing_b_until end
   where c.id = p_conversation
     and (c.user_a = v_me or c.user_b = v_me);
end;
$function$

CREATE OR REPLACE FUNCTION public.upsert_push_token(p_token text, p_platform text DEFAULT 'android'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if coalesce(p_token, '') = '' or char_length(p_token) > 4096 then
    raise exception 'INVALID_TOKEN';
  end if;
  if p_platform not in ('android','ios') then
    raise exception 'INVALID_PLATFORM';
  end if;

  insert into public.push_tokens (token, user_id, platform)
  values (p_token, auth.uid(), p_platform)
  on conflict (token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        updated_at = now();
end;
$function$
