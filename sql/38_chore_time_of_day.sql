-- ============================================================================
-- Chores belong to a part of the day
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- A flat list of everything due today is the wrong shape for how a household
-- actually runs: beds and lunchboxes are morning, bins and homework are
-- evening, and a list that mixes them makes you re-read the whole thing at
-- every hour of the day. Bucketing lets the morning list be short and finished.
--
-- Same three values and the same nullable shape as runs.time_of_day, which has
-- meant morning/afternoon/evening since 03_add_time_of_day. Reusing the
-- vocabulary rather than inventing a parallel one means the two can be read
-- together later without a translation table — and null keeps its meaning
-- there too: no particular time, do it whenever.
-- ============================================================================

alter table public.chores
  add column if not exists time_of_day text;

alter table public.chores
  drop constraint if exists chores_time_of_day_check;

alter table public.chores
  add constraint chores_time_of_day_check
  check (time_of_day in ('morning','afternoon','evening'));

-- ============================================================================
-- DONE. Existing chores keep a null time_of_day, which the app shows as
-- "Anytime" beneath the bucketed sections. Verify:
--
--   select coalesce(time_of_day,'(anytime)') as slot, count(*)
--   from public.chores group by 1 order by 1;
--
-- Note the check permits null — a chore with no particular time is a real
-- chore, not a missing value to be filled in.
-- ============================================================================
