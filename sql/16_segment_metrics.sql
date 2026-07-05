-- ============================================================================
-- Per-segment cadence / HR, so Strava laps (and manual segments) can carry the
-- exact metrics Strava reports per lap. Run in the Supabase SQL Editor.
-- Safe to run more than once.
--
-- When these are null (e.g. a manually-typed segment), the app falls back to
-- deriving cadence/HR from the run's sample stream by distance window.
-- ============================================================================

alter table public.run_segments
  add column if not exists avg_cadence smallint,   -- steps/min
  add column if not exists avg_hr      smallint,
  add column if not exists max_hr      smallint;

-- ============================================================================
-- DONE. Verify:
--   select column_name from information_schema.columns
--     where table_name='run_segments'
--       and column_name in ('avg_cadence','avg_hr','max_hr');
-- ============================================================================
