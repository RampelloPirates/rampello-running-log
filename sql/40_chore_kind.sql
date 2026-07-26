-- ============================================================================
-- Chores and to-dos are different animals
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- A chore is routine: the bins go out every Tuesday whether anyone thinks
-- about it or not, and finishing one doesn't make it go away. A to-do is a
-- thing you do once and are then done with — call the dentist, order the
-- birthday present. Mixing them means the standing weekly duties bury the
-- handful of things that actually need attention this week.
--
-- The table stays `chores`. Both are the same shape — a title, an owner, a
-- part of the day, an optional recurrence, a completion — and renaming it
-- would drag chore_completions, its composite foreign key and three policies
-- along for a label change. Same reasoning as the run log still being `runs`
-- after the app started calling it the Workout Log.
--
-- Everything that exists becomes a chore, which is what it was when it was
-- entered — there was no other kind at the time.
-- ============================================================================

alter table public.chores
  add column if not exists kind text not null default 'chore';

alter table public.chores
  drop constraint if exists chores_kind_check;

alter table public.chores
  add constraint chores_kind_check check (kind in ('chore','todo'));

create index if not exists chores_household_kind_idx
  on public.chores (household_id, kind, active, sort_order);

-- ============================================================================
-- DONE. Verify — everything you already had should read as 'chore':
--
--   select kind, count(*) from public.chores group by kind;
--
-- To reclassify something after the fact:
--
--   update public.chores set kind = 'todo' where title = 'Order the cake';
-- ============================================================================
