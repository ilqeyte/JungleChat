-- ============================================================================
-- 0305 — Hash rate-limit keys (privacy, B12).
--
-- Before this migration the bucket key was derived from the raw subject
-- (often a client IP) via private.subject_key(). That is hashed, but with a
-- FIXED, code-known prefix and no secret — so the mapping is deterministic and
-- reversible by anyone who can read rate_limit_buckets (service role).
--
-- This migration salts the key *inside* private.rate_limit so that:
--   * no call site changes (the salt is applied centrally),
--   * no future call site can leak a raw IP,
--   * historical buckets (which may carry IP-derived keys) are purged.
--
-- The salt is read from the Postgres setting app.rate_limit_salt. Provision it
-- out-of-band, e.g.:
--     alter database <db> set app.rate_limit_salt = '<long-random-hex>';
-- If unset, a built-in 'default' fallback is used so the function never errors —
-- but operators SHOULD set a real secret for the privacy guarantee to hold.
--
-- Re-runnable: idempotent recreate + a full purge of old buckets.
-- ============================================================================

create or replace function private.rate_limit(
  p_action  text,
  p_subject text,
  p_max     int,
  p_window  interval
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_raw    text := p_action || '|' || coalesce(p_subject, '');
  v_salt   text := coalesce(nullif(current_setting('app.rate_limit_salt', true), ''), 'default');
  v_key    text := encode(
                    extensions.digest(convert_to(v_raw || v_salt, 'UTF8'), 'sha256'),
                    'hex');
  v_bucket timestamptz := date_trunc('minute', now())
                          - (extract(epoch from date_trunc('minute', now()))::int % extract(epoch from p_window)::int) * interval '1 second';
  v_count  int;
begin
  insert into public.rate_limit_buckets (bucket_key, window_start, count)
  values (v_key, v_bucket, 1)
  on conflict (bucket_key, window_start)
    do update set count = public.rate_limit_buckets.count + 1
  returning count into v_count;

  if random() < 0.04 then
    delete from public.rate_limit_buckets where window_start < now() - interval '2 days';
  end if;

  if v_count > p_max then
    insert into public.security_events (event, actor_hint, details)
    values ('rate_limit.tripped', left(v_key, 16), jsonb_build_object('action', p_action));
    raise exception 'RATE_LIMITED' using hint = 'Too many requests. Try again later.';
  end if;
end;
$$;

-- client_rate_limit delegates to rate_limit, so its IP subject is salted too.
create or replace function private.client_rate_limit(p_action text, p_max int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rate_limit(p_action, private.client_ip(), p_max, p_window);
end;
$$;

-- Purge historical buckets (may contain IP-derived keys in the old format).
-- Fresh buckets are written with the salted key on the next request.
delete from public.rate_limit_buckets;
