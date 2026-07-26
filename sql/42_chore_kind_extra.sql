-- ============================================================================
-- A third kind: extras
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- 40_chore_kind split routine work from one-off tasks. This adds the third
-- thing a household actually has: work nobody is obliged to do, which pays if
-- you do it.
--
--   chore — expected. Not doing it is a shortfall.
--   todo  — a one-off that has to happen once and then stops existing.
--   extra — optional. Ignoring it costs nothing; doing it pays above base.
--
-- Extras are what makes the uncapped allowance meaningful: the routine chores
-- add up to the weekly target and the full amount, and extras are how you go
-- past it. Keeping them in their own list matters as much as the points do —
-- a bonus buried among obligations reads as another obligation.
--
-- Nothing is reclassified. Everything stays whatever it already was.
-- ============================================================================

alter table public.chores
  drop constraint if exists chores_kind_check;

alter table public.chores
  add constraint chores_kind_check check (kind in ('chore','todo','extra'));

-- ============================================================================
-- DONE. Verify the constraint takes the new value and still refuses nonsense:
--
--   select kind, count(*) from public.chores group by kind;
--
--   -- this must succeed:
--   -- update public.chores set kind = 'extra' where title = 'Wash the car';
--   -- this must fail with chores_kind_check:
--   -- update public.chores set kind = 'bonus' where title = 'Wash the car';
-- ============================================================================
