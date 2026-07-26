-- ============================================================================
-- Events are either in town or travel
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- "Who's away" is a different question from "what's on today", and a household
-- calendar has to answer both. A trip already had somewhere to go — put it in
-- the title, write the city in location — but that leaves it indistinguishable
-- from a dentist appointment to anything reading the table. Nothing could
-- style it differently on the wall, and nothing could ask how many nights
-- anyone was gone.
--
-- Two values, not a boolean, because `kind = 'travel'` reads correctly at the
-- call site where `is_travel = false` does not, and because the check
-- constraint is the natural place to add a third kind later without a column
-- rename. Same reasoning as segment_type in 33_walk_segments.
--
-- Existing rows become 'in_town': everything entered so far was local, and the
-- default keeps the app's insert path from having to care.
-- ============================================================================

alter table public.events
  add column if not exists kind text not null default 'in_town';

alter table public.events
  drop constraint if exists events_kind_check;

alter table public.events
  add constraint events_kind_check check (kind in ('in_town','travel'));

-- Travel is the minority of rows and the one you filter for, so a partial
-- index costs almost nothing and answers "when is anyone away" directly.
create index if not exists events_travel_idx
  on public.events (household_id, starts_at, start_date)
  where kind = 'travel';

-- ============================================================================
-- DONE. Verify — every existing row should be in_town, and a bad value should
-- be rejected:
--
--   select kind, count(*) from public.events group by kind;
--
--   -- this must fail with events_kind_check:
--   -- update public.events set kind = 'maybe' where id = (select id from public.events limit 1);
-- ============================================================================
