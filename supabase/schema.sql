-- =====================================================================
-- Dio TOD Signup — Database Schema
-- =====================================================================
-- Run top-to-bottom in Supabase SQL Editor (Project → SQL Editor → New query).
-- Safe to re-run: uses IF NOT EXISTS / OR REPLACE where possible. If you need
-- a clean slate, run drop_all.sql first (provided separately).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. EXTENSIONS
-- ---------------------------------------------------------------------
create extension if not exists "pgcrypto";


-- ---------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------

-- Workshops: the 10 unique sessions on offer
create table if not exists public.workshops (
  id            text     primary key,
  presenter     text     not null,
  title         text     not null,
  room          text     not null,
  display_order smallint not null
);

-- Slots: the 4 morning time blocks
create table if not exists public.slots (
  id         smallint primary key,
  start_time text     not null,
  end_time   text     not null,
  label      text     not null
);

-- Sessions: workshop × slot = 40 instances
create table if not exists public.sessions (
  id          uuid     primary key default gen_random_uuid(),
  workshop_id text     not null references public.workshops(id),
  slot_id     smallint not null references public.slots(id),
  capacity    smallint not null default 25,
  unique (workshop_id, slot_id)
);

-- Registrations: who picked what
create table if not exists public.registrations (
  user_id    uuid        not null references auth.users(id) on delete cascade,
  session_id uuid        not null references public.sessions(id) on delete cascade,
  user_email text        not null,
  user_name  text,
  created_at timestamptz not null default now(),
  primary key (user_id, session_id)
);

create index if not exists registrations_session_id_idx on public.registrations(session_id);
create index if not exists registrations_user_id_idx    on public.registrations(user_id);

-- Settings: edit cutoff + allowed email domain (so Rob can change without redeploying)
create table if not exists public.settings (
  key   text primary key,
  value text not null
);

-- Admins: who can see the admin view
create table if not exists public.admins (
  email text primary key
);


-- ---------------------------------------------------------------------
-- 3. SEED DATA
-- ---------------------------------------------------------------------

insert into public.slots (id, start_time, end_time, label) values
  (1, '08:30', '08:55', 'Slot 1 · 8:30–8:55'),
  (2, '09:00', '09:25', 'Slot 2 · 9:00–9:25'),
  (3, '09:30', '09:55', 'Slot 3 · 9:30–9:55'),
  (4, '10:00', '10:25', 'Slot 4 · 10:00–10:25')
on conflict (id) do nothing;

insert into public.workshops (id, presenter, title, room, display_order) values
  ('rob-toolkit',     'Rob',         'Dio''s own Level 2 & 3 AI toolkit',           'C134',  1),
  ('steve-gemini',    'Steve Smith', 'Google Gemini',                                'C137',  2),
  ('victor-built',    'Victor',      'I built it myself.',                            'C145',  3),
  ('susan-notebook',  'Susan',       'NotebookLM',                                    'C149',  4),
  ('andrew-fad',      'Andrew',      'Fad, or your new co-teacher? (hands-on)',       'C152',  5),
  ('angela-canva',    'Angela',      'Canva AI in your classroom',                    'C155',  6),
  ('simon-claude',    'Simon',       'Claude: your supply chain to superpowers',      'C158',  7),
  ('jo-grading',      'Jo',          'AI for grading & feedback',                     'C161',  8),
  ('zoe-gamma',       'Zoe',         'Gamma: classroom slides, made easy',            'C164',  9),
  ('chris-properly',  'Chris',       'Gemini & NotebookLM, properly',                 'C175', 10)
on conflict (id) do nothing;

-- Generate the 40 sessions (10 workshops × 4 slots)
insert into public.sessions (workshop_id, slot_id, capacity)
select w.id, s.id, 25
from public.workshops w
cross join public.slots s
on conflict (workshop_id, slot_id) do nothing;

insert into public.settings (key, value) values
  ('edit_cutoff_iso', '2026-05-08T23:59:59+12:00'),
  ('email_domain',    'diocesan.school.nz')
on conflict (key) do nothing;

insert into public.admins (email) values
  ('rmccrae@diocesan.school.nz')
on conflict (email) do nothing;


-- ---------------------------------------------------------------------
-- 4. AUTH DOMAIN RESTRICTION (defence in depth alongside GCP OAuth "Internal")
-- ---------------------------------------------------------------------
create or replace function public.enforce_email_domain()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  allowed_domain text;
begin
  select value into allowed_domain from public.settings where key = 'email_domain';
  if new.email is null or new.email not ilike '%@' || allowed_domain then
    raise exception 'Only @% accounts may register.', allowed_domain;
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_email_domain_on_signup on auth.users;
create trigger enforce_email_domain_on_signup
  before insert on auth.users
  for each row execute function public.enforce_email_domain();


-- ---------------------------------------------------------------------
-- 5. REGISTRATION RPC
-- ---------------------------------------------------------------------
-- Atomic: locks the session row, checks capacity + duplicates + cutoff,
-- inserts on success. Returns JSON: { ok: true } or { ok: false, error: '...' }.
-- ---------------------------------------------------------------------
create or replace function public.register_for_session(p_session_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid    := auth.uid();
  v_user_email  text    := auth.jwt()->>'email';
  v_user_name   text;
  v_workshop_id text;
  v_slot_id     smallint;
  v_capacity    smallint;
  v_taken       int;
  v_user_total  int;
  v_cutoff      timestamptz;
  v_domain      text;
begin
  if v_user_id is null then
    return json_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  select value into v_domain from public.settings where key = 'email_domain';
  if v_user_email !~* ('@' || v_domain || '$') then
    return json_build_object('ok', false, 'error', 'wrong_domain');
  end if;

  select value::timestamptz into v_cutoff from public.settings where key = 'edit_cutoff_iso';
  if now() >= v_cutoff then
    return json_build_object('ok', false, 'error', 'editing_closed');
  end if;

  -- Pull the user's display name from auth metadata (don't trust client input)
  select coalesce(
           raw_user_meta_data->>'full_name',
           raw_user_meta_data->>'name',
           email
         )
    into v_user_name
    from auth.users
   where id = v_user_id;

  -- Lock the session row to serialise concurrent claims for the same seat
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

  select count(*) into v_user_total from public.registrations where user_id = v_user_id;
  if v_user_total >= 4 then
    return json_build_object('ok', false, 'error', 'max_picks_reached');
  end if;

  if exists (
    select 1
      from public.registrations r
      join public.sessions s on s.id = r.session_id
     where r.user_id = v_user_id
       and s.workshop_id = v_workshop_id
  ) then
    return json_build_object('ok', false, 'error', 'workshop_already_picked');
  end if;

  if exists (
    select 1
      from public.registrations r
      join public.sessions s on s.id = r.session_id
     where r.user_id = v_user_id
       and s.slot_id = v_slot_id
  ) then
    return json_build_object('ok', false, 'error', 'slot_already_filled');
  end if;

  insert into public.registrations (user_id, session_id, user_email, user_name)
    values (v_user_id, p_session_id, v_user_email, v_user_name);

  return json_build_object('ok', true);
end;
$$;

grant execute on function public.register_for_session(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 6. UNREGISTER RPC (mirrors RPC pattern; enforces cutoff)
-- ---------------------------------------------------------------------
create or replace function public.unregister_from_session(p_session_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_cutoff  timestamptz;
  v_deleted int;
begin
  if v_user_id is null then
    return json_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  select value::timestamptz into v_cutoff from public.settings where key = 'edit_cutoff_iso';
  if now() >= v_cutoff then
    return json_build_object('ok', false, 'error', 'editing_closed');
  end if;

  delete from public.registrations
   where user_id = v_user_id and session_id = p_session_id;

  get diagnostics v_deleted = row_count;

  if v_deleted = 0 then
    return json_build_object('ok', false, 'error', 'not_registered');
  end if;

  return json_build_object('ok', true);
end;
$$;

grant execute on function public.unregister_from_session(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 7. SEAT-COUNTS RPC (aggregated, no PII leaked)
-- ---------------------------------------------------------------------
create or replace function public.get_session_seats()
returns table (
  session_id  uuid,
  workshop_id text,
  slot_id     smallint,
  capacity    smallint,
  taken       int,
  available   int
)
language sql
security definer
set search_path = public
as $$
  select
    s.id,
    s.workshop_id,
    s.slot_id,
    s.capacity,
    coalesce(count(r.user_id), 0)::int                                     as taken,
    greatest(s.capacity - coalesce(count(r.user_id), 0)::int, 0)::int      as available
  from public.sessions s
  left join public.registrations r on r.session_id = s.id
  group by s.id;
$$;

grant execute on function public.get_session_seats() to authenticated;


-- ---------------------------------------------------------------------
-- 8. ADMIN RPC (full registration list, admins only)
-- ---------------------------------------------------------------------
create or replace function public.admin_get_all_registrations()
returns table (
  user_email text,
  user_name  text,
  presenter  text,
  title      text,
  room       text,
  slot_id    smallint,
  slot_label text,
  start_time text,
  workshop_id text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if (auth.jwt()->>'email') is null
     or (auth.jwt()->>'email') not in (select email from public.admins) then
    raise exception 'forbidden';
  end if;

  return query
    select
      r.user_email,
      r.user_name,
      w.presenter,
      w.title,
      w.room,
      sl.id        as slot_id,
      sl.label     as slot_label,
      sl.start_time,
      w.id         as workshop_id,
      r.created_at
    from public.registrations r
    join public.sessions s  on s.id = r.session_id
    join public.workshops w on w.id = s.workshop_id
    join public.slots sl    on sl.id = s.slot_id
    order by sl.id, w.display_order, r.user_email;
end;
$$;

grant execute on function public.admin_get_all_registrations() to authenticated;


-- ---------------------------------------------------------------------
-- 9. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.workshops     enable row level security;
alter table public.slots         enable row level security;
alter table public.sessions      enable row level security;
alter table public.registrations enable row level security;
alter table public.admins        enable row level security;
alter table public.settings      enable row level security;

-- Public-readable schema-level data (auth required)
drop policy if exists "workshops readable" on public.workshops;
create policy "workshops readable" on public.workshops for select to authenticated using (true);

drop policy if exists "slots readable" on public.slots;
create policy "slots readable" on public.slots for select to authenticated using (true);

drop policy if exists "sessions readable" on public.sessions;
create policy "sessions readable" on public.sessions for select to authenticated using (true);

drop policy if exists "settings readable" on public.settings;
create policy "settings readable" on public.settings for select to authenticated using (true);

-- Users can read their own registrations only
drop policy if exists "users see own regs" on public.registrations;
create policy "users see own regs" on public.registrations
  for select to authenticated
  using (user_id = auth.uid());

-- INSERTs go through register_for_session() RPC (SECURITY DEFINER), so no insert policy.
-- DELETEs go through unregister_from_session() RPC (which enforces cutoff).
-- We do NOT add a generic delete policy — the RPC is the only path.

-- Admins table is admin-readable only
drop policy if exists "admins read admins" on public.admins;
create policy "admins read admins" on public.admins
  for select to authenticated
  using (auth.jwt()->>'email' in (select email from public.admins));


-- ---------------------------------------------------------------------
-- DONE
-- ---------------------------------------------------------------------
-- Sanity checks (uncomment to verify):
-- select count(*) as workshop_count from public.workshops;   -- expect 10
-- select count(*) as slot_count     from public.slots;       -- expect 4
-- select count(*) as session_count  from public.sessions;    -- expect 40
-- select * from public.get_session_seats() order by slot_id, workshop_id;
