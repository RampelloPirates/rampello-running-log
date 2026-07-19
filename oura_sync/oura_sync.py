#!/usr/bin/env python3
"""
Oura → Supabase sync (scheduled via GitHub Actions).

Reads the OAuth tokens from the `oura_tokens` table (seeded by oura_auth.py),
refreshes the access token when it's near expiry (writing the rotated token
back), then pulls daily sleep / readiness / activity summaries and the main
sleep period, merges them by day, and upserts into `oura_daily`
(dedup on user_id + day).

Env (reuses the SAME secrets as the Strava/labs sync — NO Oura-specific ones):
  SUPABASE_URL, SUPABASE_ANON_KEY
  APP_EMAIL, APP_PASSWORD        — your app sign-in
  SYNC_DAYS (optional, default 14)
"""
import os
import sys
from datetime import datetime, timedelta, timezone

import requests
from supabase import create_client

API = "https://api.ouraring.com/v2/usercollection"
TOKEN = "https://api.ouraring.com/oauth/token"


def env(key, required=False, default=None):
    v = os.environ.get(key, default)
    if required and not v:
        sys.exit(f"Missing required env var: {key}")
    return v


SUPABASE_URL = env("SUPABASE_URL", True)
SUPABASE_ANON_KEY = env("SUPABASE_ANON_KEY", True)
APP_EMAIL = env("APP_EMAIL", True)
APP_PASSWORD = env("APP_PASSWORD", True)
SYNC_DAYS = int(env("SYNC_DAYS", default="14"))


def to_int(v):
    try:
        return int(round(float(v)))
    except (TypeError, ValueError):
        return None


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def access_token(sb, user_id, row):
    """Return a valid access token, refreshing (and persisting) if needed."""
    exp = parse_ts(row.get("expires_at"))
    tok = row.get("access_token")
    now = datetime.now(timezone.utc)
    if tok and exp and exp - now > timedelta(minutes=10):
        return tok  # still good — Oura access tokens last ~30 days

    print("Refreshing Oura access token…")
    r = requests.post(TOKEN, data={
        "grant_type": "refresh_token",
        "refresh_token": row.get("refresh_token"),
        "client_id": row["client_id"],
        "client_secret": row["client_secret"],
    })
    if r.status_code != 200:
        sys.exit(
            f"Token refresh failed ({r.status_code}): {r.text}\n"
            "Re-run oura_sync/oura_auth.py to re-authorize."
        )
    t = r.json()
    new_exp = now + timedelta(seconds=int(t.get("expires_in", 86400)))
    sb.table("oura_tokens").update({
        "access_token": t["access_token"],
        # Oura rotates the refresh token — keep whichever it returned
        "refresh_token": t.get("refresh_token", row.get("refresh_token")),
        "expires_at": new_exp.isoformat(),
        "updated_at": now.isoformat(),
    }).eq("user_id", user_id).execute()
    return t["access_token"]


def fetch(path, headers, start, end):
    """Fetch a v2 usercollection route across the date range, following paging."""
    out, params = [], {"start_date": start, "end_date": end}
    while True:
        r = requests.get(f"{API}/{path}", headers=headers, params=params)
        if r.status_code != 200:
            print(f"  {path}: HTTP {r.status_code} {r.text[:180]}")
            return out
        body = r.json()
        out += body.get("data", [])
        nxt = body.get("next_token")
        if not nxt:
            return out
        params = {"start_date": start, "end_date": end, "next_token": nxt}


def pick_main_sleep(periods):
    """Choose one sleep period per day: prefer 'long_sleep', else the longest."""
    by_day = {}
    for p in periods:
        day = p.get("day")
        if not day:
            continue
        cur = by_day.get(day)
        better = (
            cur is None
            or (p.get("type") == "long_sleep" and cur.get("type") != "long_sleep")
            or (to_int(p.get("total_sleep_duration")) or 0) > (to_int(cur.get("total_sleep_duration")) or 0)
        )
        if better:
            by_day[day] = p
    return by_day


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    auth = sb.auth.sign_in_with_password({"email": APP_EMAIL, "password": APP_PASSWORD})
    sb.postgrest.auth(auth.session.access_token)
    user_id = auth.user.id

    tr = sb.table("oura_tokens").select("*").eq("user_id", user_id).execute()
    if not tr.data:
        sys.exit("No Oura tokens found — run oura_sync/oura_auth.py once first.")
    token = access_token(sb, user_id, tr.data[0])
    headers = {"Authorization": f"Bearer {token}"}

    end = datetime.now(timezone.utc).date()
    start = end - timedelta(days=SYNC_DAYS)
    s, e = start.isoformat(), end.isoformat()

    daily_sleep = fetch("daily_sleep", headers, s, e)
    readiness = fetch("daily_readiness", headers, s, e)
    activity = fetch("daily_activity", headers, s, e)
    sleep = pick_main_sleep(fetch("sleep", headers, s, e))
    # Sparse by nature — only days the walking test was actually taken. The
    # route name really is camel-cased "vO2_max" in the v2 API.
    vo2 = fetch("vO2_max", headers, s, e)
    print(f"Oura: {len(daily_sleep)} sleep, {len(readiness)} readiness, "
          f"{len(activity)} activity, {len(sleep)} sleep periods, {len(vo2)} vo2max")

    days = {}

    def day_row(d):
        return days.setdefault(d, {"user_id": user_id, "day": d})

    for x in daily_sleep:
        if x.get("day"):
            day_row(x["day"])["sleep_score"] = to_int(x.get("score"))
    for x in readiness:
        if x.get("day"):
            row = day_row(x["day"])
            row["readiness_score"] = to_int(x.get("score"))
            row["temperature_deviation"] = x.get("temperature_deviation")
    for x in activity:
        if x.get("day"):
            row = day_row(x["day"])
            row["activity_score"] = to_int(x.get("score"))
            row["steps"] = to_int(x.get("steps"))
            row["active_calories"] = to_int(x.get("active_calories"))
            row["total_calories"] = to_int(x.get("total_calories"))
    for x in vo2:
        # Field has been documented as both "vo2_max" and "score" — take either
        # rather than silently writing nothing if Oura renames it.
        v = x.get("vo2_max", x.get("score"))
        if x.get("day") and v is not None:
            day_row(x["day"])["vo2_max"] = v
    for d, p in sleep.items():
        row = day_row(d)
        row["total_sleep_seconds"] = to_int(p.get("total_sleep_duration"))
        row["time_in_bed_seconds"] = to_int(p.get("time_in_bed"))
        row["efficiency"] = to_int(p.get("efficiency"))
        row["rem_seconds"] = to_int(p.get("rem_sleep_duration"))
        row["deep_seconds"] = to_int(p.get("deep_sleep_duration"))
        row["light_seconds"] = to_int(p.get("light_sleep_duration"))
        row["avg_hrv"] = to_int(p.get("average_hrv"))
        row["resting_hr"] = to_int(p.get("lowest_heart_rate"))
        row["avg_hr"] = p.get("average_heart_rate")
        row["respiratory_rate"] = p.get("average_breath")

    if not days:
        print("No Oura data in range — nothing to write.")
        return

    now = datetime.now(timezone.utc).isoformat()
    payload = []
    for d, row in sorted(days.items()):
        row["raw"] = {k: v for k, v in row.items() if k not in ("user_id", "raw")}
        row["updated_at"] = now
        payload.append(row)

    sb.table("oura_daily").upsert(payload, on_conflict="user_id,day").execute()
    print(f"Done. Upserted {len(payload)} day(s) "
          f"({payload[0]['day']} … {payload[-1]['day']}).")


if __name__ == "__main__":
    main()
