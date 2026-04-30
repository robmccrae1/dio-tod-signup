# Dio TOD Signup

Workshop registration for Diocesan School for Girls Teacher Only Day.

- 10 workshops × 4 morning slots = 40 sessions
- 25-seat cap per session
- Up to 4 picks per staff member, no duplicate workshops, one per slot
- Google OAuth restricted to `@diocesan.school.nz`
- Editing closes 8 May 2026 23:59 NZT

## Stack

- **Frontend:** vanilla HTML + Supabase JS (CDN), no build step
- **Backend:** Supabase (Postgres + Auth + RPC)
- **Hosting:** Vercel (free Hobby tier)
- **Auth:** Google OAuth via Supabase, internal-only Workspace app

## Setup checklist (one-time)

Tick these off in order. Steps marked **(Rob)** need a human; the rest are code.

### 1. Supabase project — **(Rob, done)**

- [x] Project created: `https://fnbkuirtpwjockendkqu.supabase.co`
- [x] Publishable key in hand
- [ ] Run `supabase/schema.sql` in SQL Editor (Project → SQL Editor → New query → paste → Run)
- [ ] Verify with `select count(*) from public.sessions;` → should return **40**

### 2. Google Cloud OAuth — **(Rob)**

1. Go to [console.cloud.google.com](https://console.cloud.google.com), create a new project (e.g. `dio-tod-signup`).
2. **APIs & Services → OAuth consent screen:**
   - User type: **Internal** (this restricts to `@diocesan.school.nz` and skips Google verification)
   - App name: `Dio TOD Signup`
   - Support email: `rmccrae@diocesan.school.nz`
   - Developer contact: `rmccrae@diocesan.school.nz`
3. **APIs & Services → Credentials → Create credentials → OAuth client ID:**
   - Application type: **Web application**
   - Name: `Supabase Auth`
   - **Authorized redirect URIs:** add `https://fnbkuirtpwjockendkqu.supabase.co/auth/v1/callback`
4. Copy the **Client ID** and **Client Secret**.
5. In Supabase dashboard: **Authentication → Providers → Google** → toggle on, paste Client ID + Secret, save.
6. In Supabase dashboard: **Authentication → URL Configuration:**
   - Site URL: `https://<your-vercel-url>.vercel.app` (set after first deploy — placeholder OK for now)
   - Additional redirect URLs: same

### 3. Repo + Vercel — **(Rob)**

1. Push this repo to GitHub (instructions below).
2. Go to [vercel.com](https://vercel.com), import the GitHub repo.
3. **Framework preset:** Other (it's static).
4. **Root directory:** `public`
5. Deploy. Copy the resulting `*.vercel.app` URL.
6. Go back to Supabase → Authentication → URL Configuration → update Site URL with the real Vercel URL.
7. Update `public/config.js` if needed (currently uses values you provided).

### 4. Keep-warm cron — **(Rob, after first push)**

Free Supabase projects pause after 7 days of inactivity. The included GitHub Action pings the database daily.

In your GitHub repo: **Settings → Secrets and variables → Actions → New repository secret:**
- `SUPABASE_URL` = `https://fnbkuirtpwjockendkqu.supabase.co`
- `SUPABASE_ANON_KEY` = your publishable key

The workflow at `.github/workflows/keep-warm.yml` runs daily at 02:00 NZT.

## Running locally

It's a static site. Open `public/index.html` in a browser, or:

```bash
cd public
python3 -m http.server 8080
# then visit http://localhost:8080
```

For local dev to work with Google OAuth, you'll need to add `http://localhost:8080` to:
- Google OAuth credentials → Authorized redirect URIs (add `https://fnbkuirtpwjockendkqu.supabase.co/auth/v1/callback` is enough — Supabase handles the redirect back)
- Supabase → Auth → URL Configuration → Additional redirect URLs

## Editing the data

- **Edit cutoff:** `update public.settings set value = '2026-05-08T23:59:59+12:00' where key = 'edit_cutoff_iso';`
- **Add an admin:** `insert into public.admins (email) values ('someone@diocesan.school.nz');`
- **Change capacity for one session:** `update public.sessions set capacity = 30 where workshop_id = 'rob-toolkit' and slot_id = 1;`
- **Reset everything:** run `supabase/drop_all.sql` then `supabase/schema.sql`

## Project structure

```
dio-tod-signup/
├── public/                    # Vercel deploys this folder as static
│   ├── index.html            # main signup app
│   ├── admin.html            # admin dashboard (admins only)
│   └── config.js             # Supabase URL + publishable key
├── supabase/
│   ├── schema.sql            # full schema — run in SQL Editor
│   └── drop_all.sql          # nuke + pave (use with care)
├── scripts/
│   └── stress_test.py        # 50-client concurrent stress test
├── .github/workflows/
│   └── keep-warm.yml         # daily Supabase ping
└── README.md
```

## Pushing to GitHub (first time)

```bash
cd /Users/rmccrae/GitProjects/dio-tod-signup
git push -u origin main
```

The repo is already initialised and committed locally; first push is yours so you control credentials.
