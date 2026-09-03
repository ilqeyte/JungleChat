-- ============================================================================
-- 0303 — Fix the FK that blocks permanent user deletion (B2) and reconcile
-- push_tokens / recovery_credentials production drift.
--
-- B2: group_messages.deleted_by has NO on-delete action (defaults to NO
-- ACTION), which blocks `delete from auth.users` for any admin who ever
-- tombstoned a group message. Set it to SET NULL so a hard delete cascades
-- cleanly through the cascade chain (auth.users → profiles → group_messages).
--
-- Drift: push_tokens / recovery_credentials are referenced by 0027 but were
-- never committed as migrations (created ad-hoc on prod). On a fresh DB they
-- do not exist; on prod they may carry a NO ACTION FK to profiles. This
-- migration captures them with ON DELETE CASCADE so a hard delete cannot be
-- blocked by orphaned push/recovery rows, and so a fresh DB reproduces prod.
--
-- Re-runnable: idempotent constraint drops + guarded table creation.
-- ============================================================================

-- 1. B2: group_messages.deleted_by → SET NULL (was NO ACTION).
alter table public.group_messages
  drop constraint if exists group_messages_deleted_by_fkey,
  add constraint group_messages_deleted_by_fkey
       foreign key (deleted_by) references auth.users(id) on delete set null;

-- 2. Reconcile push_tokens / recovery_credentials (prod drift; referenced by
--    0027 but defined in no migration). Capture with ON DELETE CASCADE and
--    normalise any pre-existing FK to profiles that may be NO ACTION.
do $$
declare
  r record;
begin
  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'push_tokens'
  ) then
    create table public.push_tokens (
      id         uuid primary key default gen_random_uuid(),
      token      text not null,
      user_id    uuid not null,
      platform   text not null default 'android',
      created_at timestamptz not null default now(),
      updated_at timestamptz not null default now(),
      unique (token)
    );
  end if;

  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'recovery_credentials'
  ) then
    create table public.recovery_credentials (
      user_id         uuid primary key,
      credential_hash text not null,
      created_at      timestamptz not null default now()
    );
  end if;

  -- Normalise any FK from these tables to public.profiles → ON DELETE CASCADE.
  -- (Handles prod where the table already exists with a non-cascade FK.)
  for r in
    select con.conname as cname, con.conrelid::regclass as tbl
      from pg_constraint con
      join pg_class rel  on rel.oid  = con.conrelid
      join pg_class frel on frel.oid = con.confrelid
     where con.contype = 'f'
       and rel.relnamespace = 'public'::regnamespace
       and frel.relname = 'profiles'
       and rel.relname in ('push_tokens', 'recovery_credentials')
  loop
    execute format('alter table %s drop constraint if exists %I', r.tbl, r.cname);
  end loop;

  alter table public.push_tokens
    add constraint push_tokens_user_id_fkey
    foreign key (user_id) references public.profiles(id) on delete cascade;
  alter table public.recovery_credentials
    add constraint recovery_credentials_user_id_fkey
    foreign key (user_id) references public.profiles(id) on delete cascade;
end $$;
