-- Run this after the stress test to remove the test wrapper and any
-- leftover synthetic users.

drop function if exists public.stress_register(uuid, uuid, text);

-- Remove any synthetic users left behind (registrations cascade away via FK)
delete from auth.users where email like 'stress-test-%@diocesan.school.nz';
