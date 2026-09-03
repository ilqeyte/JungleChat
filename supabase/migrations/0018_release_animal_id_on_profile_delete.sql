-- ─── Release Animal ID on Profile Deletion ─────────────────────────────────────
-- Migration 0018: ensures that when a user profile is deleted (hard or soft),
-- their allocated animal ID is released back to the pool for reuse.

-- Trigger function to release animal ID when profile is deleted or soft-deleted
create or replace function public.release_animal_id_on_profile_delete()
returns trigger as $$
begin
  if (TG_OP = 'DELETE') or (TG_OP = 'UPDATE' and NEW.deleted_at is not null and OLD.deleted_at is null) then
    update public.animal_id
       set user_id = null, released_at = now()
     where user_id = OLD.id;
  end if;
  return NULL; -- trigger is AFTER, return value ignored
end;
$$ language plpgsql security definer;

-- Attach trigger to profiles table
drop trigger if exists trg_release_animal_id_on_profile_delete on public.profiles;
create trigger trg_release_animal_id_on_profile_delete
after delete or update on public.profiles
for each row execute function public.release_animal_id_on_profile_delete();