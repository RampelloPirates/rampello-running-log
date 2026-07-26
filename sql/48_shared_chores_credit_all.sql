-- ============================================================================
-- A chore assigned to two people pays both of them
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- "Together — one job" meant one job, and one completion row, credited to
-- whoever happened to tap it. That's wrong: if feeding the dog is both of
-- theirs, both of them are on the hook for it, and only one was getting paid
-- — the one who reached the screen first.
--
-- So a completion is now per person: ticking a shared chore writes one row
-- each. That means the uniqueness has to include the member, or the second
-- row collides with the first. One completion per person per occurrence,
-- which is what it should always have said.
--
-- Extras are deliberately NOT changing. They're up for grabs — you claim one,
-- you earn it — so the person who does it is the person who gets paid, and a
-- $5 job assigned to two kids shouldn't quietly cost $10. Chores are assigned
-- responsibilities; extras are offers. The two want different answers.
--
-- Note the rows are valued separately per person, since a tier is worth a
-- different number to each kid (46). Feeding the dog can be 3 points to one
-- and 2 to the other off the same tick.
-- ============================================================================

-- Was: unique (chore_id, due_on) where not repeatable — one completion per
-- occurrence, full stop, which made a shared chore unshareable.
drop index if exists public.chore_completions_occurrence_uniq;
create unique index if not exists chore_completions_occurrence_uniq
  on public.chore_completions (chore_id, due_on, member_id)
  where not repeatable;

-- ============================================================================
-- DONE. Verify the index now includes member_id:
--
--   select indexdef from pg_indexes
--    where tablename = 'chore_completions'
--      and indexname = 'chore_completions_occurrence_uniq';
--
-- Existing rows are untouched — a shared chore ticked before today credited
-- one person, and stays that way. It'll credit both from the next tick.
--
-- To see a shared chore paying two people once you've ticked one:
--
--   select c.title, cc.due_on, m.display_name, cc.points_earned
--     from public.chore_completions cc
--     join public.chores c on c.id = cc.chore_id
--     left join public.household_members m on m.id = cc.member_id
--    where array_length(c.assignee_ids, 1) > 1
--    order by cc.due_on desc, m.display_name;
-- ============================================================================
