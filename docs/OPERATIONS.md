# Operations playbook

How to manage the system once staff are using it. Copy-paste safe.

> **Golden rule:** before any `UPDATE` or `DELETE`, swap the verb for `SELECT *` and run it first. If the SELECT returns the rows you expect, then run the real statement. If it returns more than you expected, stop and think.

---

## Where to do things

| Task | Tool |
|---|---|
| Change capacity, deadline, admins, fix data | Supabase Dashboard → **SQL Editor** |
| Watch registrations come in / export CSV | [dio-tod-signup.vercel.app/admin](https://dio-tod-signup.vercel.app/admin) |
| Edit the website (copy, colours, layout) | Local repo → git push → Vercel auto-deploys |
| Add another OAuth provider | Supabase → Authentication → Providers |
| Check the keep-warm cron | GitHub repo → Actions tab |

---

## Common operations

### Bump capacity for one session

A specific session is filling up faster than expected and the room can hold more.

```sql
-- 1. Preview what's affected:
select s.id, w.title, sl.label, s.capacity
from public.sessions s
join public.workshops w on w.id = s.workshop_id
join public.slots sl on sl.id = s.slot_id
where s.workshop_id = 'rob-toolkit' and s.slot_id = 1;

-- 2. If correct, update:
update public.sessions
set capacity = 30
where workshop_id = 'rob-toolkit' and slot_id = 1;
```

### Bump capacity for all four slots of one workshop

```sql
update public.sessions set capacity = 30 where workshop_id = 'rob-toolkit';
```

### Bump capacity for *every* session

```sql
update public.sessions set capacity = 30;   -- yes, no WHERE here is fine
```

### Lower capacity below current registrations (BE CAREFUL)

This is allowed but will *not* automatically remove people. The session simply won't accept new joins until registrations drop below the new cap. If you need to bump people out, see "Cancel someone's pick" below.

```sql
-- See if any session is currently over the new cap:
select s.workshop_id, s.slot_id, count(r.user_id) as registered, 25 as proposed_cap
from public.sessions s
left join public.registrations r on r.session_id = s.id
group by s.id
having count(r.user_id) > 25;
```

---

### Extend the editing deadline

Staff are still picking and you want another 24 hours.

```sql
update public.settings
set value = '2026-05-09T23:59:59+12:00'
where key = 'edit_cutoff_iso';
```

Open pages will pick up the new deadline within 10 seconds (the polling cycle). No redeploy needed.

### Close registration immediately

```sql
update public.settings
set value = now()::text
where key = 'edit_cutoff_iso';
```

(Or any past timestamp.) The grid goes read-only for everyone within 10 seconds.

---

### Add or remove an admin

Granting admin to someone gives them access to `dio-tod-signup.vercel.app/admin` — they can see all registrations and export CSVs. They can't edit the database from the UI.

```sql
-- Add:
insert into public.admins (email) values ('helper@diocesan.school.nz');

-- Remove:
delete from public.admins where email = 'helper@diocesan.school.nz';
```

---

### Manually cancel someone's pick

They emailed you saying they signed up by mistake.

```sql
-- 1. See their picks:
select w.title, sl.label
from public.registrations r
join public.sessions s on s.id = r.session_id
join public.workshops w on w.id = s.workshop_id
join public.slots sl on sl.id = s.slot_id
where r.user_email = 'someone@diocesan.school.nz';

-- 2. Cancel one specific session for them:
delete from public.registrations
where user_email = 'someone@diocesan.school.nz'
  and session_id = '<paste session id from query above>';

-- 3. Or cancel everything for them:
delete from public.registrations where user_email = 'someone@diocesan.school.nz';
```

Better, if they can: tell them to log in and click their own card to cancel. The frontend handles it.

---

### Manually register someone (last resort)

If a staff member can't or won't use the website. The cleanest way is to ask them to log in once and click their picks — that gets their `auth.users` row in place. If they really can't, you can do this:

```sql
-- 1. Find the session id:
select s.id, w.title, sl.label
from public.sessions s
join public.workshops w on w.id = s.workshop_id
join public.slots sl on sl.id = s.slot_id
where w.title ilike '%canva%' and sl.id = 2;

-- 2. Find their auth.users id (only works if they've signed in at least once):
select id, email from auth.users where email = 'someone@diocesan.school.nz';

-- 3. Insert. NB: this bypasses the cap and duplicate checks — only use it
--    if you've manually verified there's a seat AND they don't already have
--    a workshop in that slot.
insert into public.registrations (user_id, session_id, user_email, user_name)
values (
  '<auth.users.id>',
  '<sessions.id>',
  'someone@diocesan.school.nz',
  'Their Name'
);
```

If they've never signed in, you can't manual-register them; they need to sign in first. Easiest workaround: ask them to log in and pick one workshop, then if they want different ones you can swap them via the admin commands above.

---

### A presenter pulls out / a workshop gets cancelled

Don't delete the workshop — that breaks the foreign keys for any registrations. Two options:

**Option A — Just notify the affected staff manually.** Pull the list:

```sql
select r.user_email, r.user_name, sl.label
from public.registrations r
join public.sessions s on s.id = r.session_id
join public.slots sl on sl.id = s.slot_id
where s.workshop_id = 'jo-grading'  -- the cancelled one
order by sl.id;
```

Email them, tell them to pick something else (assuming there's still capacity).

**Option B — Force-clear the cancelled workshop's registrations and update the title to "CANCELLED — please pick another":**

```sql
update public.workshops
set title = 'CANCELLED — pick a different workshop',
    presenter = '—'
where id = 'jo-grading';

delete from public.registrations
where session_id in (select id from public.sessions where workshop_id = 'jo-grading');
```

The cancelled workshop will still show on the grid, but the disabled-state logic won't apply to it anymore (those who were picked there now have a free slot to re-pick).

---

### Change a room

```sql
update public.workshops set room = 'C200' where id = 'rob-toolkit';
```

Open pages refresh the room within 10 seconds (next poll). Easy.

---

### See who hasn't registered yet

Requires a staff list as a CSV — the system doesn't know about staff who haven't signed in. Workaround: pull the list of who *has*:

```sql
select distinct user_email, user_name
from public.registrations
order by user_email;
```

Cross-reference with your staff list outside Supabase.

---

## Code / UI changes

If you want to tweak wording, colours, or add a feature:

```bash
cd /Users/rmccrae/GitProjects/dio-tod-signup
# edit files in public/ or supabase/
git add .
git commit -m "Tweak: <what changed>"
git push
```

Vercel auto-deploys within 30 seconds. Watch progress at [vercel.com/dashboard](https://vercel.com/dashboard).

If it's a schema change (rare), also re-run the relevant SQL in Supabase SQL Editor.

To roll back a bad deploy: go to **Vercel dashboard → Deployments**, find the previous good one, click `…` → **Promote to Production**. Live within seconds.

---

## Monitoring during the open window

A quick daily routine:

1. **Open the admin view** ([/admin](https://dio-tod-signup.vercel.app/admin)) — confirm registrations are coming in. The "Sessions full" tile tells you which workshops are popular.
2. **Check the GitHub Actions tab** for the keep-warm cron — should be a green tick from the last 24 hours. If it's red, the Supabase project may be paused; visit the dashboard to wake it.
3. **Spot-check the public site** in an incognito window — confirm the grid still loads.

If you want a numerical sanity check:

```sql
-- Are we tracking toward 250 staff each picking 4?
select count(distinct user_email) as registered_staff,
       count(*) as total_picks,
       round(count(*)::numeric / nullif(count(distinct user_email), 0), 2) as avg_picks_per_staff
from public.registrations;
```

---

## When something's broken

**Site shows "Could not load data."**
- Check [supabase.com/dashboard](https://supabase.com/dashboard) → your project. If status is "Paused", click to resume (takes ~30 seconds).
- If status is "Active", check Vercel deploy status. Roll back if needed.

**Google sign-in throws an error.**
- Check Supabase → Authentication → URL Configuration: Site URL should be `https://dio-tod-signup.vercel.app`, Redirect URLs should include the `/**` variant.
- Check Google Cloud → Credentials → your OAuth client → Authorised redirect URIs includes `https://fnbkuirtpwjockendkqu.supabase.co/auth/v1/callback`.

**Someone reports they got registered for a session that's "full."**
- Run the cap-violation check (see "Lower capacity" section above). The 25-cap is enforced by a database row lock; violations should be impossible. If you see one, tell me — it's a bug.

**The keep-warm cron is failing.**
- Open the failing run in GitHub Actions to see the error.
- Most common cause: someone rotated the Supabase publishable key. Update the `SUPABASE_ANON_KEY` repository secret.

**A staff member can't sign in.**
- Confirm they're using their `@diocesan.school.nz` Google account, not a personal one.
- Confirm the OAuth consent screen in Google Cloud is set to **Internal** (not External). External would let in non-Dio accounts.

---

## Things to NOT do

- **Don't `truncate auth.users`** — that signs everyone out and orphans registrations.
- **Don't `delete from public.workshops`** — it cascades to sessions and registrations and you lose data.
- **Don't share the service-role key** — only the publishable key belongs in client code or chat.
- **Don't `git push --force`** to main — Vercel will redeploy whatever you force-push.
- **Don't change the OAuth consent screen from Internal to External** unless you have a specific reason — Internal is your strongest domain restriction.

---

## When to ask for help

Things you can DIY:
- Capacity changes
- Cancelling/moving a single registration
- Cutoff changes
- Adding admins
- Fixing typos in `public/index.html`

Things to ask first:
- Schema changes (new tables/columns)
- Anything touching RLS or the RPCs
- Adding a new feature
- "I tried X and got an error I don't understand"

Better to ask than to break.
