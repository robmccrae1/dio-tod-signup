-- Run this in Supabase SQL Editor ONLY if you need a clean slate.
-- It nukes all the schema this project created. Will drop your registrations.

drop trigger  if exists enforce_email_domain_on_signup on auth.users;
drop function if exists public.enforce_email_domain();
drop function if exists public.register_for_session(uuid);
drop function if exists public.unregister_from_session(uuid);
drop function if exists public.get_session_seats();
drop function if exists public.admin_get_all_registrations();
drop table    if exists public.registrations cascade;
drop table    if exists public.sessions      cascade;
drop table    if exists public.workshops     cascade;
drop table    if exists public.slots         cascade;
drop table    if exists public.admins        cascade;
drop table    if exists public.settings      cascade;
