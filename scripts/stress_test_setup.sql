-- Stress-test setup. Run ONCE in the Supabase SQL Editor before running
-- scripts/stress_test.py. Run stress_test_teardown.sql after to remove it.
--
-- This creates a privileged wrapper that mirrors register_for_session but
-- accepts a synthetic user_id instead of reading it from auth.uid(). That
-- lets us simulate many concurrent users without spinning up real Google
-- OAuth sessions.
--
-- It is callable only with the service_role key, never from the browser.

create or replace function public.stress_register(
  p_session_id uuid,
  p_user_id    uuid,
  p_user_email text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_workshop_id text;
  v_slot_id     smallint;
  v_capacity    smallint;
  v_taken       int;
  v_user_total  int;
begin
  select workshop_id, slot_id, capacity
    into v_workshop_id, v_slot_id, v_capacity
    from public.sessions
   where id = p_session_id
   for update;

  if v_workshop_id is null then
    return json_build_object('ok', false, 'error', 'session_not_found');
  end if;

  select count(*) into v_taken from public.registrations where session_id = p_session_id;
  if v_taken >= v_capacity then
    return json_build_object('ok', false, 'error', 'session_full');
  end if;

  select count(*) into v_user_total from public.registrations where user_id = p_user_id;
  if v_user_total >= 4 then
    return json_build_object('ok', false, 'error', 'max_picks_reached');
  end if;

  if exists (
    select 1 from public.registrations r
      join public.sessions s on s.id = r.session_id
     where r.user_id = p_user_id and s.workshop_id = v_workshop_id
  ) then
    return json_build_object('ok', false, 'error', 'workshop_already_picked');
  end if;

  if exists (
    select 1 from public.registrations r
      join public.sessions s on s.id = r.session_id
     where r.user_id = p_user_id and s.slot_id = v_slot_id
  ) then
    return json_build_object('ok', false, 'error', 'slot_already_filled');
  end if;

  -- Synthetic users won't exist in auth.users, so we drop the FK constraint
  -- temporarily (or use a direct insert that bypasses it). The cleanest path
  -- is to disable triggers + use a session-scoped INSERT that the FK lets through
  -- because we use ON DELETE CASCADE and there's no enforcement during INSERT
  -- if the user_id is in auth.users. So: create a stress_test user first.
  --
  -- Workaround: drop the FK temporarily via a separate prep step, or insert
  -- into a parallel stress_registrations table. Simpler: insert dummy auth.users
  -- rows. We'll do that here.

  insert into auth.users (id, email, created_at, updated_at, instance_id, aud, role)
    values (p_user_id, p_user_email, now(), now(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated')
    on conflict (id) do nothing;

  insert into public.registrations (user_id, session_id, user_email, user_name)
    values (p_user_id, p_session_id, p_user_email, 'Stress Test ' || left(p_user_id::text, 8));

  return json_build_object('ok', true);
end;
$$;

-- Service role only — do NOT grant to authenticated.
revoke all on function public.stress_register(uuid, uuid, text) from public, authenticated;
grant execute on function public.stress_register(uuid, uuid, text) to service_role;

-- Note: the domain trigger (enforce_email_domain_on_signup) on auth.users
-- will block stress-test inserts unless the synthetic email ends with
-- @diocesan.school.nz. The Python harness uses that domain — keep it that way.
