-- ============================================================================
-- Link a gym session to the activity Garmin recorded for it
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- Safe to run more than once.
-- ============================================================================
--
-- A strength session logged on the watch flows Garmin → Strava → `runs` as an
-- activity_type of 'strength': it carries the duration, the heart rate and the
-- calories, but nothing about what was actually lifted. The gym module has the
-- other half — exercises, sets, reps, weight — with no idea a watch was
-- running at the time.
--
-- One nullable pointer joins them. It lives on workout_sessions rather than on
-- runs because the gym side is the optional one: every strength activity can
-- exist without a session, and a hand-logged session can exist with no watch
-- activity behind it. Deleting the activity leaves the lifting intact.
-- ============================================================================

alter table public.workout_sessions
  add column if not exists run_id uuid references public.runs(id) on delete set null;

comment on column public.workout_sessions.run_id is
  'The Garmin/Strava activity this session was recorded against, when there was one.';

-- One session per activity. Partial, so the many sessions with no activity
-- behind them are unaffected.
create unique index if not exists workout_sessions_run_idx
  on public.workout_sessions (run_id) where run_id is not null;

-- ============================================================================
-- DONE. Verify:
--   select id, worked_on, muscle_group, run_id from public.workout_sessions
--   order by worked_on desc limit 10;
-- ============================================================================
