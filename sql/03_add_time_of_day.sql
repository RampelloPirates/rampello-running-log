-- ============================================================================
-- Add time-of-day to runs so the auto-weather fetch uses a realistic hour
-- (morning / afternoon / evening) instead of always defaulting to 5pm for
-- past dates. Tampa weather swings 15+ degrees and 20+ humidity points
-- between 7am and 3pm, so the stored snapshot was often misleading.
--
-- Run once in the Supabase SQL Editor.
-- ============================================================================

alter table runs
  add column if not exists time_of_day text
  check (time_of_day in ('morning','afternoon','evening'));
