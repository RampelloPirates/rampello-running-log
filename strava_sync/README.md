# Strava → Supabase auto-sync

A scheduled worker (GitHub Actions, daily) that pulls new activities from Strava
and writes them into your `runs` table — summary metrics plus per-mile splits and
a downsampled cadence/HR/pace series (from Strava's activity streams). Since
Garmin auto-syncs to Strava, your Garmin runs flow through here with cadence/HR
intact. No manual downloads.

Replaces the (blocked) Garmin worker; uses the same DB columns from
`sql/13_garmin_sync.sql`.

> ⚠️ Strava's API terms discourage caching their data beyond 7 days. Building a
> permanent personal database from it is a gray area for personal use — your call.

## One-time setup

**1. Make sure `sql/13_garmin_sync.sql` has been run** (adds `import_ref`,
`max_cadence`, `samples`, `mile_splits` to `runs`). If you ran it during the
Garmin attempt, you're set.

**2. Create a Strava API application** — https://www.strava.com/settings/api
- Application Name: anything (e.g. "Tally sync")
- Website: anything
- **Authorization Callback Domain:** `localhost`  ← important
- Save. Note your **Client ID** and **Client Secret**.

**3. Authorize + get your refresh token** (one time, locally):

```bash
cd strava_sync
pip install requests
python strava_auth.py       # paste Client ID + Secret; a browser opens; approve
```

It prints `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET`, `STRAVA_REFRESH_TOKEN`.

**4. Add GitHub secrets** — repo → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `SUPABASE_URL` | `https://dprmpgjgjppvdlyxlubr.supabase.co` |
| `SUPABASE_ANON_KEY` | anon key from `auth.js` |
| `APP_EMAIL` | your app sign-in email |
| `APP_PASSWORD` | your app password |
| `STRAVA_CLIENT_ID` | from step 3 |
| `STRAVA_CLIENT_SECRET` | from step 3 |
| `STRAVA_REFRESH_TOKEN` | from step 3 |

**5. Test** — Actions tab → **Strava sync** → **Run workflow**. Watch the log; it
prints how many runs it imported. Then check the app.

After that it runs every morning. Adjust the time in
`.github/workflows/strava-sync.yml` (the `cron` line, UTC).

## Notes
- **Refresh token doesn't expire** unless you revoke the app's access in Strava.
- **Backfill:** bump `SYNC_DAYS` (workflow env) to import older runs.
- **Dedup:** each Strava activity imports once (`import_ref = strava:<id>`).
- **Cadence:** Strava reports running cadence per-leg; the worker doubles it to
  steps/min (with a guard against double-counting).
- **Rate limits:** Strava allows 200 req / 15 min, 2000 / day — a daily personal
  sync uses only a handful, so this is a non-issue.
