# Oura sync

Pulls your Oura Ring data into Supabase, where `oura.html` shows your recovery
at a glance — sleep / readiness / activity scores plus HRV, resting heart rate,
sleep duration and body-temperature trend over time.

Runs daily on a GitHub Actions cron (`.github/workflows/oura-sync.yml`), same as
the Strava sync.

## Why OAuth (and why tokens live in the database)

Oura **deprecated personal access tokens in December 2025** — OAuth2 is the only
option now. Its access token lasts ~30 days and it **rotates the refresh token**
on each refresh, so a static GitHub secret (the way Strava works) would go stale.
Instead the tokens live in an `oura_tokens` row in Supabase: `oura_auth.py` seeds
it once, and the daily sync refreshes and writes the rotated token back. A nice
side effect: **the sync needs no Oura-specific GitHub secrets** — it reuses the
same Supabase app login the Strava/labs sync already use.

## One-time setup

**1. Run the schema** — `sql/20_oura.sql` in the Supabase SQL Editor (adds
`oura_tokens` + `oura_daily`, per-user RLS).

**2. Create an Oura app** at <https://cloud.ouraring.com/oauth/applications>:
- Set the **Redirect URI** to exactly `http://localhost:8721/`
- Note the **Client ID** and **Client Secret**

**3. Install deps:**

```bash
pip install -r oura_sync/requirements.txt
```

**4. Authorize once** (writes tokens into Supabase). Set the same app creds the
other syncs use, then run the auth script:

```bash
export SUPABASE_URL=https://dprmpgjgjppvdlyxlubr.supabase.co
export SUPABASE_ANON_KEY=...      # anon key from auth.js
export APP_EMAIL=...              # your app sign-in email
export APP_PASSWORD=...

python oura_sync/oura_auth.py
```

On Windows PowerShell, set vars with `$env:APP_EMAIL="..."` etc. It opens a
browser to authorize, then stores the tokens.

**5. First pull / backfill.** Run locally, or trigger the workflow from the
Actions tab. For a one-time history backfill, pass a big `days`:

```bash
SYNC_DAYS=400 python oura_sync/oura_sync.py
```

That's it — no new GitHub secrets. The existing `SUPABASE_URL`,
`SUPABASE_ANON_KEY`, `APP_EMAIL`, `APP_PASSWORD` secrets cover it, and the daily
cron takes over from here.

## What it pulls

Per day (dedup on `user_id + day`), merged from four Oura v2 endpoints:

| Field | Source |
|---|---|
| `sleep_score` | `daily_sleep.score` |
| `readiness_score`, `temperature_deviation` | `daily_readiness` |
| `activity_score`, `steps`, calories | `daily_activity` |
| `total_sleep_seconds`, `efficiency`, REM/deep/light | main `sleep` period |
| `avg_hrv`, `resting_hr`, `avg_hr`, `respiratory_rate` | main `sleep` period |

`resting_hr` is the sleep period's `lowest_heart_rate`. When a day has more than
one sleep period (e.g. a nap), the main nightly sleep (`long_sleep`, else the
longest) is used. The full merged payload is also kept in a `raw` JSON column.

## Notes

- **Refresh handling** is automatic; you only re-run `oura_auth.py` if you revoke
  access or the refresh chain breaks (the sync tells you if it does).
- **Rate limits:** Oura is generous for personal use; the daily 14-day window is
  a handful of requests.
