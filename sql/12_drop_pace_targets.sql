-- ============================================================================
-- Remove the pace-targets feature
-- Run in: Supabase Dashboard → SQL Editor.
--
-- Pace targets were coach-set in the old team model; with the personal-health
-- pivot there's no coach, and the feature has been removed from the front-end
-- (log_run.html no longer reads or displays targets). Dropping the table.
-- Optional — the app no longer touches this table either way; this just tidies
-- the schema. Safe to run more than once.
-- ============================================================================

drop table if exists public.pace_targets cascade;

-- DONE. Verify:  select to_regclass('public.pace_targets');   -- expect: null
