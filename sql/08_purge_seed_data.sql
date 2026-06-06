-- ============================================================================
-- Purge the fake/demo seed data before going live with real athletes.
-- Run in: Supabase Dashboard → SQL Editor.
--
-- What's "fake":
--   * Demo athletes from seed_demo_data.sql — all use @piratesdemo.test emails.
--   * Seeded runs — every seeded run (the demo set AND 05_seed_last_week.sql)
--     was inserted with created_by = NULL. The new authenticated app stamps
--     created_by with the signed-in user, so "created_by IS NULL" = not logged
--     by a real signed-in person.
--
-- What's KEPT:
--   * Coaches (Sowell, Jeff, etc.) — untouched.
--   * Any real athletes you've added to the roster — only their fake seeded
--     runs are removed; the athlete records stay.
--
-- run_segments and race_results cascade-delete with their run / athlete, so
-- you only delete from runs and athletes.
--
-- ⚠️ Recommended: run STEP 0 first and eyeball the counts before running the
-- DELETEs. Once committed, these deletes are not reversible.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- STEP 0 — preview. Run this alone first; nothing is deleted.
-- ---------------------------------------------------------------------------
select 'demo athletes to delete'            as item, count(*) as rows
  from athletes where email ilike '%@piratesdemo.test'
union all
select 'seeded runs to delete (created_by null)', count(*)
  from runs where created_by is null
union all
select 'real athletes kept',                  count(*)
  from athletes where email not ilike '%@piratesdemo.test'
union all
select 'real runs kept (created_by set)',     count(*)
  from runs where created_by is not null
union all
select 'coaches kept',                        count(*)
  from coaches;

-- ---------------------------------------------------------------------------
-- STEP 1 — delete every fake/seeded run (demo + last-week seed). This also
-- removes their run_segments and race_results via ON DELETE CASCADE.
--
-- NOTE: this clears ALL runs that weren't logged through the new signed-in app.
-- Since the old open-demo logging also left created_by NULL, anything logged
-- before this auth launch is treated as fake and removed — that's the
-- clean-slate intent. (If you knowingly logged a real keeper run during the
-- demo, export/copy it before running this.)
-- ---------------------------------------------------------------------------
delete from runs where created_by is null;

-- ---------------------------------------------------------------------------
-- STEP 2 — delete the demo athletes themselves (the @piratesdemo.test roster).
-- Their runs are already gone from STEP 1; this removes the people.
-- ---------------------------------------------------------------------------
delete from athletes where email ilike '%@piratesdemo.test';

-- ---------------------------------------------------------------------------
-- STEP 3 — verify the clean slate.
-- ---------------------------------------------------------------------------
select
  (select count(*) from runs)                                        as runs_left,
  (select count(*) from run_segments)                                as segments_left,
  (select count(*) from race_results)                                as race_results_left,
  (select count(*) from athletes)                                    as athletes_left,
  (select count(*) from athletes where email ilike '%@piratesdemo.test') as demo_athletes_left,
  (select count(*) from coaches)                                     as coaches_left;
