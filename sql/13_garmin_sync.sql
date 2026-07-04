-- ============================================================================
-- Columns for the automatic Garmin sync worker (garmin_sync/).
-- Run in: Supabase Dashboard → SQL Editor. Safe to run more than once.
--
-- The worker imports runs with their time-series. These columns hold the extra
-- data (dedup key, max cadence, a downsampled sample series, and per-mile
-- splits) on the existing runs table. samples/mile_splits are read by the
-- (upcoming) run-detail / chart view.
-- ============================================================================

alter table public.runs
  add column if not exists import_ref  text,        -- e.g. 'garmin:123456789' (dedup)
  add column if not exists max_cadence smallint,    -- steps/min
  add column if not exists samples     jsonb,       -- downsampled [{t,mi,cad,hr,pace}]
  add column if not exists mile_splits jsonb;        -- [{mile,seconds,avg_cadence,avg_hr,max_hr}]

-- One run per Garmin activity per athlete (lets the worker skip already-imported).
create unique index if not exists runs_import_ref_idx
  on public.runs (athlete_id, import_ref)
  where import_ref is not null;

-- ============================================================================
-- DONE. Verify:
--   select column_name from information_schema.columns
--     where table_name='runs' and column_name in
--       ('import_ref','max_cadence','samples','mile_splits');
-- ============================================================================
