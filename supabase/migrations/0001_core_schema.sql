-- ============================================================================
-- JUNGLECHAT — 0001_core_schema.sql
-- Core tables, enums, constraints, indexes.
--
-- SECURITY MODEL:
--   * The `authenticated`/`anon` roles receive NO direct INSERT/UPDATE/DELETE
--     grants on these tables. Every mutation goes through SECURITY DEFINER
--     functions that enforce authorization server-side.
--   * Public identity (ANIMAL-123) is stored separately from the internal
--     auth.users UUID and is never used as an authorization identifier.
-- ============================================================================

-- pgcrypto: cryptographically secure randomness + password hash verification.
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- Enums
-- ----------------------------------------------------------------------------
create type public.account_status as enum ('active', 'muted', 'suspended', 'banned');
create type public.room_kind       as enum ('builtin', 'temporary', 'user');
create type public.request_status  as enum ('pending', 'accepted', 'denied', 'cancelled', 'expired', 'blocked');
create type public.report_type     as enum ('user_report', 'message_report', 'room_report', 'bug_report', 'error_report', 'other');
create type public.report_status   as enum ('open', 'investigating', 'resolved', 'dismissed');
create type public.mute_scope      as enum ('conversation', 'room');

-- ----------------------------------------------------------------------------
-- profiles — internal account identity + privacy settings + moderation state.
-- id == auth.users.id (random UUID; NEVER the public Animal ID).
-- ----------------------------------------------------------------------------
create table public.profiles (
  id                      uuid primary key references auth.users(id) on delete cascade,
  animal                  text not null,
  animal_number           int  not null,
  display_animal_id       text not null unique,          -- e.g. WOLF-427 (display/discovery only)
  open_to_talk            boolean not null default true,
  random_talk_enabled     boolean not null default true,
  status                  public.account_status not null default 'active',
  last_active_at          timestamptz not null default now(),
  inactivity_warning_sent smallint not null default 0,   -- highest warning day sent: 0/80/85/89
  deleted_at              timestamptz,
  created_at              timestamptz not null default now(),
  constraint profiles_animal_chk   check (char_length(animal) between 3 and 20),
  constraint profiles_anum_chk     check (animal_number between 1 and 999999),
  constraint profiles_deleted_chk  check (deleted_at is null or status = 'banned')
);
create index profiles_discovery_idx on public.profiles (open_to_talk, status)
  where deleted_at is null;
create index profiles_animal_idx on public.profiles (animal)
  where deleted_at is null;

-- ----------------------------------------------------------------------------
-- animal_id — atomic allocation ledger. Unique (animal, number) pair prevents
-- duplicate identities at the storage layer even under race conditions.
-- released_at marks IDs eligible for reuse after genuine deletion.
-- ----------------------------------------------------------------------------
create table public.animal_id (
  animal      text not null,
  number      int  not null,
  user_id     uuid references auth.users(id) on delete set null,
  allocated_at timestamptz not null default now(),
  released_at  timestamptz,
  primary key (animal, number),
  constraint animal_id_user_unique unique (user_id)
);

-- ----------------------------------------------------------------------------
-- rooms
-- ----------------------------------------------------------------------------
create table public.rooms (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  name        text not null,
  description text not null default '',
  kind        public.room_kind not null default 'user',
  is_private  boolean not null default false,
  owner_id    uuid references auth.users(id) on delete set null,
  expires_at  timestamptz,                       -- temporary rooms only
  is_active   boolean not null default true,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint rooms_name_len_chk check (char_length(name) between 1 and 60),
  constraint rooms_desc_len_chk check (char_length(description) <= 280),
  constraint rooms_slug_chk     check (slug ~ '^[a-z0-9-]{1,60}$'),
  constraint rooms_temp_expiry_chk check (kind <> 'temporary' or expires_at is not null)
);
create index rooms_kind_idx on public.rooms (kind, is_active);

-- ----------------------------------------------------------------------------
-- room_members
-- ----------------------------------------------------------------------------
create table public.room_members (
  room_id   uuid not null references public.rooms(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index room_members_user_idx on public.room_members (user_id);

-- ----------------------------------------------------------------------------
-- messages — public room messages.
-- ----------------------------------------------------------------------------
create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  sender_id  uuid not null references auth.users(id) on delete cascade,
  content    text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  constraint messages_content_chk check (char_length(content) between 1 and 1000)
);
create index messages_room_time_idx on public.messages (room_id, created_at desc);

-- ----------------------------------------------------------------------------
-- conversations — private chats (only after accepted talk request).
-- user_a/user_b ordered so the pair is unique.
-- ----------------------------------------------------------------------------
create table public.conversations (
  id              uuid primary key default gen_random_uuid(),
  user_a          uuid not null references auth.users(id) on delete cascade,
  user_b          uuid not null references auth.users(id) on delete cascade,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz,
  constraint conversations_pair_chk check (user_a < user_b),
  constraint conversations_pair_unique unique (user_a, user_b)
);
create index conversations_user_a_idx on public.conversations (user_a);
create index conversations_user_b_idx on public.conversations (user_b);

-- ----------------------------------------------------------------------------
-- direct_messages
-- ----------------------------------------------------------------------------
create table public.direct_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references auth.users(id) on delete cascade,
  content         text not null,
  created_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  deleted_by      uuid references auth.users(id) on delete set null,
  constraint dm_content_chk check (char_length(content) between 1 and 1000)
);
create index dm_conv_time_idx on public.direct_messages (conversation_id, created_at desc);

-- ----------------------------------------------------------------------------
-- talk_requests
-- ----------------------------------------------------------------------------
create table public.talk_requests (
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  target_id    uuid not null references auth.users(id) on delete cascade,
  status       public.request_status not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  expires_at   timestamptz not null default (now() + interval '7 days'),
  constraint tr_not_self_chk   check (requester_id <> target_id),
  constraint tr_responded_chk  check (responded_at is null or responded_at >= created_at)
);
create index tr_target_idx    on public.talk_requests (target_id, status);
create index tr_requester_idx on public.talk_requests (requester_id, status);

-- ----------------------------------------------------------------------------
-- blocks — enforced server-side everywhere discovery/messaging happens.
-- ----------------------------------------------------------------------------
create table public.blocks (
  blocker_id uuid not null references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_not_self_chk check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on public.blocks (blocked_id);

-- ----------------------------------------------------------------------------
-- mutes — UX feature only, never a security control.
-- ----------------------------------------------------------------------------
create table public.mutes (
  user_id     uuid not null references auth.users(id) on delete cascade,
  scope       public.mute_scope not null,
  scope_id    text not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, scope, scope_id)
);

-- ----------------------------------------------------------------------------
-- reports — reporter identity is internal-only; never exposed via API views.
-- human_ref is a display reference such as R-1842.
-- ----------------------------------------------------------------------------
create table public.reports (
  id                bigint generated always as identity primary key,
  human_ref         text not null unique,
  reporter_id       uuid references auth.users(id) on delete set null,
  type              public.report_type not null,
  target_user_id    uuid references auth.users(id) on delete set null,
  target_message_id uuid references public.messages(id) on delete set null,
  target_room_id    uuid references public.rooms(id) on delete set null,
  body              text not null,
  status            public.report_status not null default 'open',
  resolution_note   text,
  resolved_by       uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint reports_body_chk check (char_length(body) between 1 and 2000)
);
create index reports_status_idx on public.reports (status, created_at desc);

-- ----------------------------------------------------------------------------
-- notifications — payload contains ONLY fixed template kinds + minimal routing
-- ids the recipient needs to navigate inside the app. Never message content,
-- never other users' Animal IDs.
-- ----------------------------------------------------------------------------
create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null,
  payload    jsonb not null default '{}'::jsonb,
  read_at    timestamptz,
  created_at timestamptz not null default now(),
  constraint notifications_kind_chk check (kind ~ '^[a-z_]{2,40}$')
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);

-- ----------------------------------------------------------------------------
-- moderation_actions — every admin action lands here (also feeds audit view).
-- ----------------------------------------------------------------------------
create table public.moderation_actions (
  id          bigint generated always as identity primary key,
  admin_id    uuid not null references auth.users(id) on delete cascade,
  action      text not null,
  target_type text not null,
  target_id   text not null,
  reason      text not null default '',
  created_at  timestamptz not null default now(),
  constraint mod_action_chk check (action ~ '^[a-z_]{2,40}$'),
  constraint mod_target_chk check (target_type ~ '^[a-z_]{2,30}$')
);

-- ----------------------------------------------------------------------------
-- admin_roles — separate from normal accounts. Backend-enforced only.
-- ----------------------------------------------------------------------------
create table public.admin_roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  granted_by uuid references auth.users(id) on delete set null,
  granted_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- admin_audit_logs — append-only. No UPDATE/DELETE grants exist anywhere,
-- including for definer functions except a dedicated rotate function.
-- ----------------------------------------------------------------------------
create table public.admin_audit_logs (
  id         bigint generated always as identity primary key,
  actor_id   uuid references auth.users(id) on delete set null,
  event      text not null,
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint audit_event_chk check (event ~ '^[a-z_.]{2,60}$')
);

-- ----------------------------------------------------------------------------
-- rate_limit_buckets — fixed-window counters maintained by the rate limiter
-- function (0002). Keyed by hashed subject so raw IPs are not persisted.
-- ----------------------------------------------------------------------------
create table public.rate_limit_buckets (
  bucket_key   text not null,
  window_start timestamptz not null,
  count        int not null default 0,
  primary key (bucket_key, window_start)
);

-- ----------------------------------------------------------------------------
-- security_events — failed logins, authorization failures, suspicious activity
-- (rate-limit trips). Contains NO credentials and NO message content.
-- ----------------------------------------------------------------------------
create table public.security_events (
  id         bigint generated always as identity primary key,
  event      text not null,
  actor_hint text not null default '',   -- hashed/truncated subject only
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index security_events_time_idx on public.security_events (created_at desc);

-- ============================================================================
-- updated_at trigger helper
-- ============================================================================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger reports_updated_at
  before update on public.reports
  for each row execute function public.set_updated_at();
