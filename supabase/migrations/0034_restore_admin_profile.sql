-- ============================================================================
-- JUNGLECHAT — 0034_restore_admin_profile.sql
--
-- Repair: the Adam (admin) AUTH account (aa663d9c-a5f2-436c-8e8e-8d7bd28e6b52)
-- survived the user-deletion work, but its public.profiles ROW was deleted.
-- Consequences before this repair:
--   • list_my_conversations joins the other member's profile — with Adam's
--     row missing, his support conversation dropped out of the recipient's
--     Chats list entirely (messages "stuck in notifications").
--   • Adam's display identity is unresolvable everywhere.
-- His admin_roles row was intact (admin gates passed), and the original
-- identity could not be recovered from the animal_id ledger (no row kept).
--
-- This repair re-creates the profile through the same storage rules the
-- signup Edge Function uses: a fresh (animal, number) pair is written to the
-- atomic animal_id ledger (unique constraint prevents duplicates), then the
-- profile row is inserted with the derived display id. Idempotent: does
-- nothing if the profile already exists. Adam can change his animal via the
-- in-app change-animal flow afterwards.
-- ============================================================================

do $$
declare
  v_adam     uuid := 'aa663d9c-a5f2-436c-8e8e-8d7bd28e6b52';
  v_animal   text := 'Owl';
  v_number   int;
  v_tries    int  := 0;
  v_display  text;
begin
  if exists (select 1 from public.profiles where id = v_adam) then
    return;  -- already repaired
  end if;
  if not exists (select 1 from auth.users where id = v_adam) then
    -- On a clean install the original "Adam" admin auth account does not
    -- exist, so there is nothing to repair. Skip silently rather than fail
    -- the whole migration batch on a fresh project.
    return;
  end if;

  -- Atomically claim a free number for the chosen animal (1..999999).
  loop
    v_tries := v_tries + 1;
    v_number := 100000 + floor(random() * 899999)::int;
    begin
      insert into public.animal_id (animal, number, user_id)
      values (v_animal, v_number, v_adam);
      exit;
    exception when unique_violation then
      if v_tries >= 25 then
        raise exception 'NO_FREE_ANIMAL_NUMBER';
      end if;
    end;
  end loop;

  v_display := upper(v_animal) || '-' || v_number::text;

  insert into public.profiles (id, animal, animal_number, display_animal_id, status)
  values (v_adam, v_animal, v_number, v_display, 'active');
end;
$$;
