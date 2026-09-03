-- ============================================================================
-- JUNGLECHAT — 0003_rls_policies.sql
--
-- DENY BY DEFAULT.
--   1. Revoke ALL table privileges from anon/authenticated (Supabase grants
--      ALL by default — this is undone explicitly).
--   2. Enable RLS on every table (no policy = no access).
--   3. Grant back ONLY surgical SELECTs whose policies encode the privacy
--      rules: shadow mode, blocks, membership, ownership, deletion state.
--   4. ALL writes happen through SECURITY DEFINER functions only.
--
-- Internal/privileged tables (animal_id ledger, rate limits, security events,
-- audit logs, moderation actions, admin_roles) receive NO client grants at all.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Strip default broad grants
-- ----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles','animal_id','rooms','room_members','messages',
    'conversations','direct_messages','talk_requests','blocks','mutes',
    'reports','notifications','moderation_actions','admin_roles',
    'admin_audit_logs','rate_limit_buckets','security_events'
  ]
  loop
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2) Enable RLS everywhere
-- ----------------------------------------------------------------------------
alter table public.profiles            enable row level security;
alter table public.animal_id           enable row level security;
alter table public.rooms               enable row level security;
alter table public.room_members        enable row level security;
alter table public.messages            enable row level security;
alter table public.conversations       enable row level security;
alter table public.direct_messages     enable row level security;
alter table public.talk_requests       enable row level security;
alter table public.blocks              enable row level security;
alter table public.mutes               enable row level security;
alter table public.reports             enable row level security;
alter table public.notifications       enable row level security;
alter table public.moderation_actions  enable row level security;
alter table public.admin_roles         enable row level security;
alter table public.admin_audit_logs    enable row level security;
alter table public.rate_limit_buckets  enable row level security;
alter table public.security_events     enable row level security;

-- Force RLS even for table owners (defense in depth).
alter table public.profiles            force row level security;
alter table public.animal_id           force row level security;
alter table public.rooms               force row level security;
alter table public.room_members        force row level security;
alter table public.messages            force row level security;
alter table public.conversations       force row level security;
alter table public.direct_messages     force row level security;
alter table public.talk_requests       force row level security;
alter table public.blocks              force row level security;
alter table public.mutes               force row level security;
alter table public.reports             force row level security;
alter table public.notifications       force row level security;
alter table public.moderation_actions  force row level security;
alter table public.admin_roles         force row level security;
alter table public.admin_audit_logs    force row level security;
alter table public.rate_limit_buckets  force row level security;
alter table public.security_events     force row level security;

-- ----------------------------------------------------------------------------
-- 3) Profiles — minimal public card; shadow mode honored; conversation and
--    pending-request participants always visible to each other (needed for
--    chat UI), regardless of later shadow-mode changes.
-- ----------------------------------------------------------------------------
grant select on public.profiles to authenticated;

create policy profiles_select_self
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

create policy profiles_select_discoverable
  on public.profiles for select
  to authenticated
  using (
    deleted_at is null
    and status = 'active'
    and open_to_talk
    and id <> auth.uid()
    and not exists (
      select 1 from public.blocks b
       where (b.blocker_id = auth.uid() and b.blocked_id = profiles.id)
          or (b.blocker_id = profiles.id and b.blocked_id = auth.uid())
    )
  );

create policy profiles_select_conversation_partner
  on public.profiles for select
  to authenticated
  using (
    exists (
      select 1 from public.conversations c
       where (c.user_a = auth.uid() and c.user_b = profiles.id)
          or (c.user_b = auth.uid() and c.user_a = profiles.id)
    )
    or exists (
      select 1 from public.talk_requests tr
       where tr.status = 'pending'
         and ((tr.requester_id = auth.uid() and tr.target_id = profiles.id)
           or (tr.target_id = auth.uid() and tr.requester_id = profiles.id))
    )
  );

-- animal_id allocation ledger: NEVER readable or writable by clients.
-- (no grants, RLS enabled => fully denied)

-- ----------------------------------------------------------------------------
-- Rooms — visible when active & not expired; private user rooms only for
-- members/owner.
-- ----------------------------------------------------------------------------
grant select on public.rooms to authenticated;

create policy rooms_select_visible
  on public.rooms for select
  to authenticated
  using (
    is_active
    and (expires_at is null or expires_at > now())
    and (
      kind in ('builtin', 'temporary')
      or not is_private
      or owner_id = auth.uid()
      or exists (
        select 1 from public.room_members m
         where m.room_id = rooms.id and m.user_id = auth.uid()
      )
    )
  );

-- ----------------------------------------------------------------------------
-- Room membership — you can see your own memberships only. Aggregate counts
-- ("N animals here") come exclusively from a definer RPC that returns counts,
-- never identities.
-- ----------------------------------------------------------------------------
grant select on public.room_members to authenticated;

create policy room_members_select_own
  on public.room_members for select
  to authenticated
  using (user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- Messages — readable only inside visible rooms; soft-deleted hidden.
-- No INSERT/UPDATE/DELETE grants: sending goes through send_room_message().
-- ----------------------------------------------------------------------------
grant select on public.messages to authenticated;

create policy messages_select_visible_room
  on public.messages for select
  to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.rooms r
       where r.id = messages.room_id
         and r.is_active
         and (r.expires_at is null or r.expires_at > now())
         and (
           r.kind in ('builtin', 'temporary')
           or not r.is_private
           or r.owner_id = auth.uid()
           or exists (
             select 1 from public.room_members m
              where m.room_id = r.id and m.user_id = auth.uid()
           )
         )
    )
  );

-- ----------------------------------------------------------------------------
-- Conversations & direct messages — strictly participants only.
-- ----------------------------------------------------------------------------
grant select on public.conversations to authenticated;

create policy conversations_select_participant
  on public.conversations for select
  to authenticated
  using (user_a = auth.uid() or user_b = auth.uid());

grant select on public.direct_messages to authenticated;

create policy dm_select_participant
  on public.direct_messages for select
  to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.conversations c
       where c.id = direct_messages.conversation_id
         and (c.user_a = auth.uid() or c.user_b = auth.uid())
    )
  );

-- ----------------------------------------------------------------------------
-- Talk requests — parties only.
-- ----------------------------------------------------------------------------
grant select on public.talk_requests to authenticated;

create policy talk_requests_select_party
  on public.talk_requests for select
  to authenticated
  using (requester_id = auth.uid() or target_id = auth.uid());

-- ----------------------------------------------------------------------------
-- Blocks — you may see whom YOU blocked. Being blocked stays invisible.
-- ----------------------------------------------------------------------------
grant select on public.blocks to authenticated;

create policy blocks_select_own
  on public.blocks for select
  to authenticated
  using (blocker_id = auth.uid());

-- ----------------------------------------------------------------------------
-- Mutes — own rows only (UX feature).
-- ----------------------------------------------------------------------------
grant select on public.mutes to authenticated;

create policy mutes_select_own
  on public.mutes for select
  to authenticated
  using (user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- Reports — reporter sees own report status; admins see all via admin RPCs
-- (not direct table grants).
-- ----------------------------------------------------------------------------
grant select on public.reports to authenticated;

create policy reports_select_own
  on public.reports for select
  to authenticated
  using (reporter_id = auth.uid());

-- ----------------------------------------------------------------------------
-- Notifications — recipient only. Payload templates are privacy-safe by
-- construction (enforced by the writer functions).
-- ----------------------------------------------------------------------------
grant select on public.notifications to authenticated;

create policy notifications_select_own
  on public.notifications for select
  to authenticated
  using (user_id = auth.uid());
create policy notifications_update_read_own
  on public.notifications for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- The ONLY client-side mutation allowed in the entire system: marking your own
-- notification as read. Everything else goes through server functions.
grant update (read_at) on public.notifications to authenticated;

-- ----------------------------------------------------------------------------
-- Fully sealed tables: moderation_actions, admin_roles, admin_audit_logs,
-- rate_limit_buckets, security_events, animal_id.
-- RLS enabled + zero grants => unreachable from anon/authenticated.
-- Admin reads audit data through definer RPCs only.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Realtime publication — tables broadcast changes ONLY through their RLS
-- policies above, so unauthorized subscriptions receive nothing.
-- ----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.messages;
    alter publication supabase_realtime add table public.direct_messages;
    alter publication supabase_realtime add table public.talk_requests;
    alter publication supabase_realtime add table public.notifications;
    alter publication supabase_realtime add table public.rooms;
  end if;
exception
  when duplicate_object then null;  -- already added
end;
$$;
