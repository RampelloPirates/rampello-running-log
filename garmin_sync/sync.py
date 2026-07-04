#!/usr/bin/env python3
"""
Garmin → Supabase sync worker (runs on a schedule via GitHub Actions).

For each recent Garmin activity it doesn't already have, it inserts a row into
`runs` with the summary metrics plus, from the activity's FIT file, a per-mile
split table and a downsampled cadence/HR/pace series (for the run-detail view).

Env (set as GitHub secrets):
  SUPABASE_URL, SUPABASE_ANON_KEY   — from your Supabase project
  APP_EMAIL, APP_PASSWORD           — your app sign-in (email+password auth)
  GARMIN_TOKENS_BASE64              — from gen_token.py
  SYNC_DAYS (optional, default 4)   — how many days back to check each run
"""
import base64
import io
import os
import sys
import tempfile
import zipfile
from datetime import date, timedelta

from garminconnect import Garmin
from fitparse import FitFile
from supabase import create_client


# ── env ──────────────────────────────────────────────────────────────────────
def env(key, default=None, required=False):
    v = os.environ.get(key, default)
    if required and not v:
        sys.exit(f"Missing required env var: {key}")
    return v


SUPABASE_URL = env("SUPABASE_URL", required=True)
SUPABASE_ANON_KEY = env("SUPABASE_ANON_KEY", required=True)
APP_EMAIL = env("APP_EMAIL", required=True)
APP_PASSWORD = env("APP_PASSWORD", required=True)
SYNC_DAYS = int(env("SYNC_DAYS", "4"))


# ── helpers ──────────────────────────────────────────────────────────────────
def clamp(v, lo, hi):
    try:
        v = int(round(float(v)))
    except (TypeError, ValueError):
        return None
    return v if lo <= v <= hi else None


def time_of_day(local):
    try:
        h = int(str(local).split(" ")[1].split(":")[0])
    except Exception:
        return None
    return "morning" if h < 12 else ("afternoon" if h < 17 else "evening")


def steps_per_min(rec):
    """FIT running cadence is rev/min; steps/min = (cadence + fractional) * 2."""
    c = rec.get("cadence")
    if c is None:
        return None
    c = c + (rec.get("fractional_cadence") or 0)
    if c < 130:
        c = c * 2
    return int(round(c))


def extract_fit(data):
    if data[:2] == b"PK":  # a zip
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            fits = [n for n in z.namelist() if n.lower().endswith(".fit")]
            if not fits:
                raise ValueError("no .fit inside download")
            return z.read(fits[0])
    return data


def parse_records(fit_bytes):
    ff = FitFile(io.BytesIO(fit_bytes))
    recs = []
    for m in ff.get_messages("record"):
        d = {f.name: f.value for f in m}
        if d.get("timestamp") is not None:
            recs.append(d)
    return recs


def downsample(records, n=150):
    if not records:
        return None
    t0 = records[0]["timestamp"]
    step = max(1, len(records) // n)
    out = []
    for r in records[::step]:
        sp = r.get("enhanced_speed") or r.get("speed")  # m/s
        out.append({
            "t": int((r["timestamp"] - t0).total_seconds()),
            "mi": round((r.get("distance") or 0) / 1609.344, 3),
            "cad": steps_per_min(r),
            "hr": r.get("heart_rate"),
            "pace": int(round(1609.344 / sp)) if sp and sp > 0 else None,  # sec/mi
        })
    return out


def compute_splits(records):
    recs = [r for r in records if r.get("distance") is not None]
    if not recs:
        return None
    splits = []
    mile = 1
    seg_start_t = recs[0]["timestamp"]
    cad_sum = hr_sum = hr_max = cnt = hr_cnt = 0
    mi = 0.0
    for r in recs:
        mi = r["distance"] / 1609.344
        c = steps_per_min(r)
        hr = r.get("heart_rate")
        if c:
            cad_sum += c
            cnt += 1
        if hr:
            hr_sum += hr
            hr_max = max(hr_max, hr)
            hr_cnt += 1
        while mi >= mile:
            splits.append({
                "mile": mile,
                "seconds": int((r["timestamp"] - seg_start_t).total_seconds()),
                "avg_cadence": int(cad_sum / cnt) if cnt else None,
                "avg_hr": int(hr_sum / hr_cnt) if hr_cnt else None,
                "max_hr": hr_max or None,
            })
            mile += 1
            seg_start_t = r["timestamp"]
            cad_sum = hr_sum = hr_max = cnt = hr_cnt = 0
    # trailing partial mile
    if cnt or hr_cnt:
        splits.append({
            "mile": mile,
            "partial": round(mi - (mile - 1), 2),
            "seconds": int((recs[-1]["timestamp"] - seg_start_t).total_seconds()),
            "avg_cadence": int(cad_sum / cnt) if cnt else None,
            "avg_hr": int(hr_sum / hr_cnt) if hr_cnt else None,
            "max_hr": hr_max or None,
        })
    return splits


# ── main ─────────────────────────────────────────────────────────────────────
def main():
    # Supabase (sign in as the app user so inserts respect RLS / land on your row)
    sb = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    auth = sb.auth.sign_in_with_password({"email": APP_EMAIL, "password": APP_PASSWORD})
    sb.postgrest.auth(auth.session.access_token)
    user_id = auth.user.id
    prof = sb.table("athletes").select("id").execute()
    if not prof.data:
        sys.exit("No athlete profile found for this account — sign into the app once first.")
    athlete_id = prof.data[0]["id"]

    # Garmin (token-based login — no password/MFA needed here)
    tokens_b64 = env("GARMIN_TOKENS_BASE64", required=True)
    tokendir = tempfile.mkdtemp()
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(tokens_b64))) as z:
        z.extractall(tokendir)
    garmin = Garmin()
    garmin.login(tokendir)

    end = date.today()
    start = end - timedelta(days=SYNC_DAYS)
    activities = garmin.get_activities_by_date(start.isoformat(), end.isoformat())
    print(f"Garmin returned {len(activities)} activities in {start}..{end}")

    added = 0
    for act in activities:
        aid = act.get("activityId")
        ref = f"garmin:{aid}"
        try:
            exists = (sb.table("runs").select("id")
                      .eq("athlete_id", athlete_id).eq("import_ref", ref).execute())
            if exists.data:
                continue

            tkey = (act.get("activityType") or {}).get("typeKey", "") or ""
            is_run = "run" in tkey.lower()
            start_local = act.get("startTimeLocal") or ""
            dist_mi = (act.get("distance") or 0) / 1609.344
            dur_s = int(act.get("duration") or act.get("elapsedDuration") or 0)

            row = {
                "athlete_id": athlete_id,
                "created_by": user_id,
                "import_ref": ref,
                "run_date": (start_local.split(" ")[0] if start_local else end.isoformat()),
                "time_of_day": time_of_day(start_local),
                "run_type": "easy" if is_run else "cross_train",
                "distance_miles": round(min(dist_mi, 999.99), 2) if dist_mi > 0 else None,
                "duration_seconds": dur_s or None,
                "avg_hr": clamp(act.get("averageHR"), 30, 240),
                "max_hr": clamp(act.get("maxHR"), 30, 240),
                "avg_cadence": clamp(act.get("averageRunningCadenceInStepsPerMinute"), 100, 250),
                "max_cadence": clamp(act.get("maxRunningCadenceInStepsPerMinute"), 100, 250),
                "notes": f"Garmin: {act.get('activityName')}" if act.get("activityName") else "Imported from Garmin",
            }
            if not is_run:
                row["cross_train_activity"] = tkey or "other"

            # FIT time-series (best effort — a run still imports if this fails)
            try:
                data = garmin.download_activity(aid, dl_fmt=Garmin.ActivityDownloadFormat.ORIGINAL)
                records = parse_records(extract_fit(data))
                row["samples"] = downsample(records)
                row["mile_splits"] = compute_splits(records)
            except Exception as e:
                print(f"  {ref}: time-series skipped ({e})")

            sb.table("runs").insert(row).execute()
            added += 1
            print(f"  imported {ref} — {row['run_date']} {row.get('distance_miles')}mi")
        except Exception as e:
            print(f"  {ref}: FAILED ({e})")

    print(f"Done. Imported {added} new run(s).")


if __name__ == "__main__":
    main()
