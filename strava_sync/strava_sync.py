#!/usr/bin/env python3
"""
Strava → Supabase sync (scheduled via GitHub Actions).

Refreshes a Strava access token, pulls recent activities, and inserts new ones
into `runs` — summary metrics plus, from the activity streams, per-mile splits
and a downsampled cadence/HR/pace series (same columns the manual FIT importer
uses). Dedups on import_ref = 'strava:<id>'.

Env (GitHub secrets):
  SUPABASE_URL, SUPABASE_ANON_KEY
  APP_EMAIL, APP_PASSWORD                          — your app sign-in
  STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET, STRAVA_REFRESH_TOKEN  — from strava_auth.py
  SYNC_DAYS (optional, default 7)
"""
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import requests
from supabase import create_client

API = "https://www.strava.com/api/v3"


def env(key, required=False, default=None):
    v = os.environ.get(key, default)
    if required and not v:
        sys.exit(f"Missing required env var: {key}")
    return v


SUPABASE_URL = env("SUPABASE_URL", True)
SUPABASE_ANON_KEY = env("SUPABASE_ANON_KEY", True)
APP_EMAIL = env("APP_EMAIL", True)
APP_PASSWORD = env("APP_PASSWORD", True)
CLIENT_ID = env("STRAVA_CLIENT_ID", True)
CLIENT_SECRET = env("STRAVA_CLIENT_SECRET", True)
REFRESH_TOKEN = env("STRAVA_REFRESH_TOKEN", True)
SYNC_DAYS = int(env("SYNC_DAYS", default="7"))


def clamp(v, lo, hi):
    try:
        v = int(round(float(v)))
    except (TypeError, ValueError):
        return None
    return v if lo <= v <= hi else None


def steps_per_min(c):
    """Strava running cadence is rev/min (one leg); steps/min = *2."""
    if c is None:
        return None
    c = c * 2 if c < 130 else c
    return int(round(c))


def time_of_day(iso_local):
    try:
        h = int(iso_local[11:13])
    except Exception:
        return None
    return "morning" if h < 12 else ("afternoon" if h < 17 else "evening")


def activity_type_from_sport(sport):
    """Map a Strava sport_type/type to our activity vocabulary."""
    s = (sport or "").lower()
    if "run" in s:
        return "run"
    if "ride" in s or "cycl" in s or "bike" in s or "handcycle" in s:
        return "ride"
    if "swim" in s:
        return "swim"
    if "walk" in s:
        return "walk"
    if "hike" in s:
        return "hike"
    if "weight" in s or "strength" in s or "crossfit" in s:
        return "strength"
    if any(k in s for k in ("workout", "yoga", "pilates", "hiit", "elliptical", "stair")):
        return "workout"
    return "other"


def strava_access_token():
    r = requests.post("https://www.strava.com/oauth/token", data={
        "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET,
        "grant_type": "refresh_token", "refresh_token": REFRESH_TOKEN,
    })
    r.raise_for_status()
    return r.json()["access_token"]


def compute_from_streams(s):
    t = (s.get("time") or {}).get("data")
    dist = (s.get("distance") or {}).get("data")          # meters
    hr = (s.get("heartrate") or {}).get("data")
    cad = (s.get("cadence") or {}).get("data")            # rev/min
    vel = (s.get("velocity_smooth") or {}).get("data")    # m/s
    if not t or not dist:
        return None, None, None
    n = len(t)

    step = max(1, n // 150)
    samples = []
    for i in range(0, n, step):
        sp = vel[i] if vel and i < len(vel) else None
        samples.append({
            "t": int(t[i]),
            "mi": round((dist[i] or 0) / 1609.344, 3),
            "cad": steps_per_min(cad[i]) if cad and i < len(cad) else None,
            "hr": hr[i] if hr and i < len(hr) else None,
            "pace": int(round(1609.344 / sp)) if sp and sp > 0 else None,
        })

    splits = []
    mile = 1
    seg_start = t[0]
    cad_sum = hr_sum = hr_max = c_cnt = h_cnt = max_cad = 0
    mi = 0.0
    for i in range(n):
        mi = (dist[i] or 0) / 1609.344
        sc = steps_per_min(cad[i]) if cad and i < len(cad) else None
        h = hr[i] if hr and i < len(hr) else None
        if sc:
            cad_sum += sc; c_cnt += 1; max_cad = max(max_cad, sc)
        if h:
            hr_sum += h; hr_max = max(hr_max, h); h_cnt += 1
        while mi >= mile:
            splits.append({
                "mile": mile, "seconds": int(t[i] - seg_start),
                "avg_cadence": int(cad_sum / c_cnt) if c_cnt else None,
                "avg_hr": int(hr_sum / h_cnt) if h_cnt else None,
                "max_hr": hr_max or None,
            })
            mile += 1; seg_start = t[i]
            cad_sum = hr_sum = hr_max = c_cnt = h_cnt = 0
    if c_cnt or h_cnt:
        splits.append({
            "mile": mile, "partial": round(mi - (mile - 1), 2),
            "seconds": int(t[-1] - seg_start),
            "avg_cadence": int(cad_sum / c_cnt) if c_cnt else None,
            "avg_hr": int(hr_sum / h_cnt) if h_cnt else None,
            "max_hr": hr_max or None,
        })
    return samples, splits, (max_cad or None)


def build_laps(sid, headers):
    """Pull an activity's laps and turn them into run_segments rows — but only
    when they look like a real workout (2+ laps that vary in distance). Uniform
    auto 1-mile laps are skipped since the per-mile splits already cover those.
    Segment type is auto-guessed from lap pace (fast=interval, slow=rest); the
    user can re-classify in the app."""
    try:
        r = requests.get(f"{API}/activities/{sid}/laps", headers=headers)
        if r.status_code != 200:
            return None
        laps = r.json()
    except Exception:
        return None
    if not laps or len(laps) < 2:
        return None

    dists = [(l.get("distance") or 0) / 1609.344 for l in laps]
    maxd, mind = max(dists), min(dists)
    if maxd <= 0 or (maxd - mind) / maxd < 0.25:
        return None  # near-uniform laps → leave it to the per-mile splits

    paces = []
    for l in laps:
        d = (l.get("distance") or 0) / 1609.344
        t = l.get("moving_time") or l.get("elapsed_time") or 0
        paces.append((t / d) if d > 0 and t > 0 else None)
    valid = sorted(p for p in paces if p)
    med = valid[len(valid) // 2] if valid else None

    rows = []
    for i, l in enumerate(laps):
        d = (l.get("distance") or 0) / 1609.344
        t = int(l.get("moving_time") or l.get("elapsed_time") or 0)
        p = (t / d) if d > 0 and t > 0 else None
        seg_type = "easy"
        if med and p:
            if p <= 0.90 * med:
                seg_type = "interval"
            elif p >= 1.15 * med:
                seg_type = "rest"
        rows.append({
            "segment_order": l.get("lap_index") or (i + 1),
            "segment_type": seg_type,
            "distance_miles": round(d, 2) if d > 0 else None,
            "duration_seconds": t or None,
            "avg_cadence": clamp(steps_per_min(l.get("average_cadence")), 100, 250) if l.get("average_cadence") else None,
            "avg_hr": clamp(l.get("average_heartrate"), 30, 240),
            "max_hr": clamp(l.get("max_heartrate"), 30, 240),
        })
    return rows


# ── Stream backfill ─────────────────────────────────────────────────────────
# The import loop fetches streams per activity, and Strava rate-limits per 15
# minutes. A big one-time backfill blows straight through that, so the tail of
# it lands as summary-only rows — and because the importer dedups on
# import_ref, the next sync skips them and those streams are lost for good.
# That would quietly gut personal bests, VDOT and decoupling, all of which read
# the sample stream.
#
# So: a bounded pass that fills in whatever is still missing, newest first. It
# stops the moment it is rate-limited and picks up where it left off on the next
# sync, which turns a backfill that needs thousands of requests into something
# that completes over a few days without ever tripping the quota.
STREAM_BACKFILL_LIMIT = int(env("STREAM_BACKFILL_LIMIT", default="40"))

def backfill_streams(sb, headers, athlete_id):
    try:
        q = (sb.table("runs")
             .select("id,import_ref,run_date")
             .eq("athlete_id", athlete_id)
             .like("import_ref", "strava:%")
             .is_("samples", "null")
             .order("run_date", desc=True)
             .limit(STREAM_BACKFILL_LIMIT).execute())
    except Exception as e:
        print(f"Stream backfill skipped ({e})")
        return
    rows = q.data or []
    if not rows:
        print("Streams: nothing to backfill.")
        return

    print(f"Streams: {len(rows)} run(s) missing a stream; filling newest first")
    filled = 0
    for r in rows:
        ref = r.get("import_ref") or ""
        if ":" not in ref:
            continue
        sid = ref.split(":", 1)[1]
        try:
            sr = requests.get(f"{API}/activities/{sid}/streams", headers=headers,
                              params={"keys": "time,distance,heartrate,cadence,velocity_smooth",
                                      "key_by_type": "true"}, timeout=30)
            if sr.status_code == 429:
                print(f"  rate-limited after {filled}; the rest resume on the next sync")
                break
            if sr.status_code != 200:
                print(f"  {r['run_date']}: HTTP {sr.status_code}")
                continue
            samples, splits, max_cad = compute_from_streams(sr.json())
            if not samples:
                continue          # no HR/distance data on this one; nothing to store
            patch = {"samples": samples, "mile_splits": splits}
            if max_cad:
                patch["max_cadence"] = clamp(max_cad, 100, 250)
            sb.table("runs").update(patch).eq("id", r["id"]).execute()
            filled += 1
            time.sleep(1)         # same courtesy as the import loop
        except Exception as e:
            print(f"  {r['run_date']}: stream backfill failed ({e})")
    print(f"Streams: filled {filled} run(s).")


# ── Weather ─────────────────────────────────────────────────────────────────
# Strava returns no weather, so runs imported by this worker arrive without it.
# That matters beyond decoration: dewpoint is what the weather-adjusted pace
# analysis regresses against, and with it null on every synced run there is
# nothing to fit. Open-Meteo needs no key; one range request covers the whole
# backlog, so this tops up anything missing on every sync and quietly does
# nothing once history is filled.
WEATHER_LAT, WEATHER_LON = 27.95, -82.46      # Tampa, FL (same point log_run.html uses)
WEATHER_HOURLY = "temperature_2m,relativehumidity_2m,dewpoint_2m,windspeed_10m"

def hour_for_time_of_day(tod):
    return {"morning": 7, "afternoon": 15, "evening": 19}.get(tod or "", 17)

def _weather_call(url, params):
    """Fetch one Open-Meteo range into {'YYYY-MM-DDTHH:00': {...}}."""
    out = {}
    try:
        r = requests.get(url, params=params, timeout=30)
        if r.status_code != 200:
            print(f"  weather: HTTP {r.status_code} {r.text[:120]}")
            return out
        h = (r.json() or {}).get("hourly") or {}
        times = h.get("time") or []
        for i, stamp in enumerate(times):
            def at(key):
                arr = h.get(key) or []
                return arr[i] if i < len(arr) else None
            out[stamp] = {
                "temperature_f": at("temperature_2m"),
                "humidity_percent": at("relativehumidity_2m"),
                "dewpoint_f": at("dewpoint_2m"),
                "wind_mph": at("windspeed_10m"),
            }
    except Exception as e:
        print(f"  weather: {e}")
    return out

def weather_index(start_iso, end_iso):
    """Hourly weather across a date range. The archive is authoritative but lags
    about five days, so the recent tail comes from the forecast endpoint."""
    common = {
        "latitude": WEATHER_LAT, "longitude": WEATHER_LON, "hourly": WEATHER_HOURLY,
        "temperature_unit": "fahrenheit", "windspeed_unit": "mph", "timezone": "America/New_York",
    }
    idx = {}
    archive_end = (datetime.now(timezone.utc).date() - timedelta(days=6)).isoformat()
    if start_iso <= min(end_iso, archive_end):
        idx.update(_weather_call("https://archive-api.open-meteo.com/v1/archive",
                                 {**common, "start_date": start_iso, "end_date": min(end_iso, archive_end)}))
    # Forecast covers the last ~92 days including the tail the archive hasn't
    # caught up on; let it win on any overlap.
    recent_start = max(start_iso, (datetime.now(timezone.utc).date() - timedelta(days=90)).isoformat())
    if recent_start <= end_iso:
        idx.update(_weather_call("https://api.open-meteo.com/v1/forecast",
                                 {**common, "start_date": recent_start, "end_date": end_iso}))
    return idx

def backfill_weather(sb, athlete_id):
    try:
        q = (sb.table("runs")
             .select("id,run_date,time_of_day")
             .eq("athlete_id", athlete_id)
             .is_("dewpoint_f", "null")
             .order("run_date", desc=False)
             .limit(600).execute())
    except Exception as e:
        print(f"Weather backfill skipped ({e})")
        return
    rows = [r for r in (q.data or []) if r.get("run_date")]
    if not rows:
        print("Weather: nothing to backfill.")
        return

    start, end = rows[0]["run_date"], max(r["run_date"] for r in rows)
    print(f"Weather: filling {len(rows)} run(s), {start} … {end}")
    idx = weather_index(start, end)
    if not idx:
        print("Weather: no data returned; leaving runs as they are.")
        return

    filled = 0
    for r in rows:
        key = f"{r['run_date']}T{hour_for_time_of_day(r.get('time_of_day')):02d}:00"
        w = idx.get(key)
        if not w or w.get("dewpoint_f") is None:
            continue
        patch = {
            "temperature_f": None if w["temperature_f"] is None else int(round(w["temperature_f"])),
            "humidity_percent": None if w["humidity_percent"] is None else int(round(w["humidity_percent"])),
            "dewpoint_f": int(round(w["dewpoint_f"])),
            "wind_mph": None if w["wind_mph"] is None else round(float(w["wind_mph"]), 1),
        }
        try:
            sb.table("runs").update(patch).eq("id", r["id"]).execute()
            filled += 1
        except Exception as e:
            print(f"  {r['run_date']}: weather update failed ({e})")
    print(f"Weather: filled {filled} run(s).")


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    auth = sb.auth.sign_in_with_password({"email": APP_EMAIL, "password": APP_PASSWORD})
    sb.postgrest.auth(auth.session.access_token)
    user_id = auth.user.id
    prof = sb.table("athletes").select("id").execute()
    if not prof.data:
        sys.exit("No athlete profile found — sign into the app once first.")
    athlete_id = prof.data[0]["id"]

    headers = {"Authorization": f"Bearer {strava_access_token()}"}
    after = int((datetime.now(timezone.utc) - timedelta(days=SYNC_DAYS)).timestamp())

    activities, page = [], 1
    while True:
        r = requests.get(f"{API}/athlete/activities", headers=headers,
                         params={"after": after, "per_page": 50, "page": page})
        r.raise_for_status()
        batch = r.json()
        activities += batch
        if len(batch) < 50:
            break
        page += 1
    print(f"Strava returned {len(activities)} activities in the last {SYNC_DAYS} days")

    added = 0
    for a in activities:
        sid = a.get("id")
        ref = f"strava:{sid}"
        try:
            ex = (sb.table("runs").select("id")
                  .eq("athlete_id", athlete_id).eq("import_ref", ref).execute())
            if ex.data:
                continue

            sport = a.get("sport_type") or a.get("type") or ""
            activity_type = activity_type_from_sport(sport)
            start_local = a.get("start_date_local") or ""
            dist_mi = (a.get("distance") or 0) / 1609.344

            row = {
                "athlete_id": athlete_id,
                "created_by": user_id,
                "import_ref": ref,
                "run_date": (start_local[:10] if start_local
                             else datetime.now(timezone.utc).date().isoformat()),
                "time_of_day": time_of_day(start_local),
                "activity_type": activity_type,
                "sub_type": None,   # Strava doesn't classify runs; set it later in the app
                "distance_miles": round(min(dist_mi, 999.99), 2) if dist_mi > 0 else None,
                "duration_seconds": int(a.get("moving_time") or a.get("elapsed_time") or 0) or None,
                "avg_hr": clamp(a.get("average_heartrate"), 30, 240),
                "max_hr": clamp(a.get("max_heartrate"), 30, 240),
                "avg_cadence": clamp(steps_per_min(a.get("average_cadence")), 100, 250) if a.get("average_cadence") else None,
                "notes": f"Strava: {a.get('name')}" if a.get("name") else "Imported from Strava",
            }

            try:
                sr = requests.get(f"{API}/activities/{sid}/streams", headers=headers,
                                  params={"keys": "time,distance,heartrate,cadence,velocity_smooth",
                                          "key_by_type": "true"})
                if sr.status_code == 200:
                    samples, splits, max_cad = compute_from_streams(sr.json())
                    row["samples"] = samples
                    row["mile_splits"] = splits
                    if max_cad:
                        row["max_cadence"] = clamp(max_cad, 100, 250)
                elif sr.status_code == 429:
                    print("  rate-limited on streams; stopping for this run")
            except Exception as e:
                print(f"  {ref}: streams skipped ({e})")

            res = sb.table("runs").insert(row).execute()
            run_id = res.data[0]["id"] if getattr(res, "data", None) else None

            # Pull Strava's laps as structured segments (workouts only).
            if run_id and activity_type == "run":
                laps = build_laps(sid, headers)
                if laps:
                    for lp in laps:
                        lp["run_id"] = run_id
                    try:
                        sb.table("run_segments").insert(laps).execute()
                        print(f"    + {len(laps)} lap segment(s)")
                    except Exception as e:
                        print(f"  {ref}: laps skipped ({e})")

            added += 1
            print(f"  imported {ref} — {row['run_date']} {row.get('distance_miles')}mi")
            time.sleep(1)  # gentle on rate limits
        except Exception as e:
            print(f"  {ref}: FAILED ({e})")

    print(f"Done. Imported {added} new run(s).")
    backfill_streams(sb, headers, athlete_id)
    backfill_weather(sb, athlete_id)


if __name__ == "__main__":
    main()
