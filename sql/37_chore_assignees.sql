-- ============================================================================
-- A chore can belong to several people
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- chores.assigned_to held exactly one person, which cannot express either of
-- the two things a household actually wants:
--
--   "you two do the dishes together"  — one job, several people
--   "you each tidy your own room"     — several jobs that happen to share a name
--
-- The first needs an array. The second doesn't need anything: separate tasks
-- are separate rows, and saying so keeps every downstream thing simple —
-- each person gets their own completion, their own history, and can have
-- theirs edited or deleted without touching anyone else's. The app inserts one
-- chore per person when you pick "each"; nothing here has to model it.
--
-- That also leaves chore_completions alone. Its unique index is
-- (chore_id, due_on) — one completion per occurrence — which stays exactly
-- right once "each" means separate chores. Had the split been modelled inside
-- a single row, that index would have needed to become conditional on a mode
-- stored in another table.
--
-- assigned_to is backfilled and dropped in the same script, so there's no
-- window where two columns both claim to say who owns a chore.
-- ============================================================================

alter table public.chores
  add column if not exists assignee_ids uuid[] not null default '{}';

-- Backfill before the drop. Guarded so re-running can't clobber edits made
-- after the first run.
update public.chores
   set assignee_ids = array[assigned_to]
 where assigned_to is not null
   and assignee_ids = '{}';

alter table public.chores
  drop column if exists assigned_to;

-- "What am I on the hook for" is the query the Mine filter runs.
create index if not exists chores_assignees_idx
  on public.chores using gin (assignee_ids);

-- ============================================================================
-- DONE. Verify — the old column is gone and everyone who had a chore still
-- has it:
--
--   select title, assignee_ids from public.chores order by sort_order;
--
--   select column_name from information_schema.columns
--    where table_schema='public' and table_name='chores'
--      and column_name in ('assigned_to','assignee_ids');
--   -- expect one row: assignee_ids
--
-- An empty array means "anyone", the same way an empty events.attendee_ids
-- means "the family".
-- ============================================================================
