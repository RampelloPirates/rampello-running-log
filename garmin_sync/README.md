# Garmin → Supabase auto-sync

A scheduled worker that logs into Garmin Connect, pulls new activities, and
writes them into your `runs` table (summary metrics + per-mile splits + a
downsampled cadence/HR/pace series). Runs daily on **GitHub Actions** (free),
so runs appear in the app automatically — no manual file downloads.

Not part of the website — Vercel ignores this folder; GitHub Actions runs it.

> ⚠️ It uses the **unofficial** `garminconnect` library (not Garmin's approved
> partner API). It works well but is technically against Garmin's ToS and can
> break if Garmin changes their login. Personal use, your account, your call.

## One-time setup

**1. Run the SQL** — `sql/13_garmin_sync.sql` in the Supabase SQL Editor (adds
the columns the worker fills).

**2. Make sure you have an app login** — the worker signs into Supabase as you
(email + password auth). If you haven't set a password, do that first (Supabase
dashboard → Auth → Users), and sign into the app once so your athlete profile
exists.

**3. Generate a Garmin token** (handles MFA once, locally):

```bash
cd garmin_sync
pip install garminconnect
python gen_token.py        # enter Garmin email/password + MFA code if prompted
```

Copy the long base64 string it prints.

**4. Add GitHub secrets** — repo → Settings → Secrets and variables → Actions →
New repository secret, for each:

| Secret | Value |
|---|---|
| `SUPABASE_URL` | `https://dprmpgjgjppvdlyxlubr.supabase.co` |
| `SUPABASE_ANON_KEY` | the anon key from `auth.js` (or Supabase → Project Settings → API) |
| `APP_EMAIL` | your app sign-in email |
| `APP_PASSWORD` | your app password |
| `GARMIN_TOKENS_BASE64` | the string from step 3 |

**5. Test it** — repo → **Actions** tab → **Garmin sync** → **Run workflow**.
Watch the log; it should print how many runs it imported. Then check the app.

After that it runs every morning on its own. Change the time in
`.github/workflows/garmin-sync.yml` (the `cron` line, in UTC).

## Notes / troubleshooting
- **First run is the shakeout.** Garmin's field names occasionally differ by
  device/account; if the log shows an error, paste it and it's a quick fix.
- **Token expiry.** The Garmin token lasts about a year. When it stops working,
  re-run `gen_token.py` and update the `GARMIN_TOKENS_BASE64` secret.
- **MFA.** Handled once in `gen_token.py`; the scheduled job uses the saved
  token, so it never needs your password or a code.
- **Dedup.** Each Garmin activity is imported once (`import_ref = garmin:<id>`).
  Safe to re-run; it skips what it already has.
- **Backfill.** Bump `SYNC_DAYS` (workflow env) temporarily to import older runs.
