-- ============================================================================
-- Oura Ring integration — sleep / readiness / activity + HRV, resting HR, temp.
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Two tables, both per-user (scoped to auth.uid()):
--   oura_tokens  — one row: your OAuth app credentials + the current access /
--                  refresh tokens. Seeded once by oura_sync/oura_auth.py and
--                  kept fresh by the daily sync (Oura rotates the refresh token,
--                  and its access token lasts ~30 days, so we persist them here
--                  instead of in a static GitHub secret).
--   oura_daily   — one row per day of ring data (dedup on user_id + day).
--
-- Why store the client secret in the DB? So the GitHub Actions sync needs NO
-- new secrets — it reuses the same Supabase app login the Strava/labs sync use,
-- reads everything from oura_tokens, and writes the rotated token back.
-- ============================================================================

create table if not exists public.oura_tokens (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  client_id     text not null,
  client_secret text not null,
  access_token  text,
  refresh_token text,
  expires_at    timestamptz,                     -- when access_token stops working
  updated_at    timestamptz not null default now()
);

alter table public.oura_tokens enable row level security;
drop policy if exists "own oura tokens" on public.oura_tokens;
create policy "own oura tokens" on public.oura_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table if not exists public.oura_daily (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references auth.users(id) on delete cascade,
  day                    date not null,
  sleep_score            int,                    -- 0–100 (daily_sleep)
  readiness_score        int,                    -- 0–100 (daily_readiness)
  activity_score         int,                    -- 0–100 (daily_activity)
  total_sleep_seconds    int,                    -- main sleep period
  time_in_bed_seconds    int,
  efficiency             int,                    -- % (sleep period)
  rem_seconds            int,
  deep_seconds           int,
  light_seconds          int,
  avg_hrv                int,                    -- ms (average_hrv)
  resting_hr             int,                    -- bpm (lowest_heart_rate in sleep)
  avg_hr                 numeric,                -- bpm (average_heart_rate in sleep)
  respiratory_rate       numeric,                -- breaths/min (average_breath)
  temperature_deviation  numeric,                -- °C from baseline (readiness)
  steps                  int,
  active_calories        int,
  total_calories         int,
  raw                    jsonb,                  -- merged day payload, future-proofing
  updated_at             timestamptz not null default now(),
  unique (user_id, day)
);

create index if not exists oura_daily_user_day_idx on public.oura_daily (user_id, day desc);

alter table public.oura_daily enable row level security;
drop policy if exists "own oura daily" on public.oura_daily;
create policy "own oura daily" on public.oura_daily
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- DONE. Verify:  select day, sleep_score, readiness_score, avg_hrv, resting_hr
--                from public.oura_daily order by day desc limit 14;
-- ============================================================================
