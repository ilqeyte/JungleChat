# Migrations — read before adding one

## Numbering: use `0300` and up

`supabase db push` applies migrations in **lexical filename order**, not numeric
order. Two historical files use a 3-digit prefix while the rest use 4 digits:

```
0001_core_schema.sql
...
0044_change_animal_alloc_hardening.sql
019_group_invitation_system.sql      <-- 3-digit, sorts AFTER every 004x
020_auto_delete_timer.sql            <-- 3-digit, sorts AFTER every 004x
```

Because `"0045" < "019_"` (character 2: `0` vs `1`), a new migration named
`0045_something.sql` sorts **before** `019` and `020`.

**Why that matters:** on production this is harmless — `019`/`020` are already
recorded as applied, so `db push` only runs the new file. But on a **fresh
database build** (disaster recovery, a new staging project, `supabase db reset`)
the whole set replays in lexical order, and `0045` would run *before* the group
invitation system and the auto-delete columns exist. Any foreign key or column
reference into `019`/`020` would fail.

**Therefore: new migrations start at `0300_`.** Any prefix from `0300` upward
sorts after both `0044` and `020_`, so fresh builds and incremental pushes agree.

Do **not** "fix" this by renaming `019`/`020` to 4 digits. They are already
applied in production; renaming changes the recorded version and `supabase db
push` will report the database as out of sync.

## Rules

1. **Append-only.** Never edit a migration that has been applied. `db push` does
   not re-run it, so the database silently diverges from this repository. Add a
   new migration that corrects the problem. CI enforces this
   (`scripts/ci/check_migrations.py`) by failing if a migration present in the
   base commit is modified or deleted.
2. **Every `SECURITY DEFINER` function must pin `search_path`**
   (`set search_path = ''`). Without it the function is hijackable via the
   caller's `search_path`. CI enforces this.
3. **Every new table in `public` needs RLS enabled** and an explicit policy.
   Tables are deny-by-default (`AGENTS.md` rule 3). Tables in `private` are
   exempt — they are protected by schema-level `revoke`.
4. **Fully qualify references** inside `SECURITY DEFINER` functions
   (`public.foo`, `private.bar`) since the search path is empty.

## Deployment

Migrations are **not** auto-applied on merge. They are applied by the
`Supabase Deploy` workflow, which is `workflow_dispatch` only and gated behind
an environment. Every PR gets the read-only `Supabase Validate` workflow
(append-only, ordering, and security lint) automatically.

The Supabase access token lives in the `SUPABASE_ACCESS_TOKEN` repository
secret. It is never committed. See `docs/IMPLEMENTATION_PLAN.md` Phase 0.
