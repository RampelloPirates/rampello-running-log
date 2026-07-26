-- ============================================================================
-- Extras are priced in money, and some of them can be done twice
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Points, dollars, and why extras get to break the rule
-- ----------------------------------------------------
-- Routine chores carry points precisely so no obligation ever wears a price
-- tag — a child who knows brushing their teeth is worth fifty cents starts
-- declining the cheap ones. Extras are the opposite case. Nobody has to do
-- them, so the number IS the incentive: "mow the lawn, $5" is the entire
-- proposition, and hiding it behind a points ratio would only make the offer
-- harder to understand.
--
-- It also leaks nothing. An extra worth $5 says nothing about what a routine
-- chore is worth, because extras are added to the allowance rather than
-- divided out of it:
--
--     earned = points/target * base   +   sum(extras done this week)
--
-- Repeatable, and how "once a week" is enforced
-- ---------------------------------------------
-- Folding a load of laundry can happen four times in an evening. Mowing the
-- lawn cannot happen twice in a week — or rather it can, but it isn't paid
-- twice. Rather than teach the app a second rule, non-repeatable extras are
-- recorded against the MONDAY of the pay week instead of the day they were
-- done, so the existing (chore_id, due_on) uniqueness enforces once-a-week
-- with no new constraint and no way to get round it by waiting a day.
--
-- Repeatable ones need that uniqueness gone, so it becomes a partial index
-- and the flag is copied onto the completion — the index can't reach across
-- to chores to ask, and the answer has to stay true for rows already written
-- even if the chore is later changed.
-- ============================================================================

alter table public.chores
  add column if not exists extra_cents integer not null default 0,
  add column if not exists repeatable  boolean not null default false;

alter table public.chores
  drop constraint if exists chores_extra_cents_check;
alter table public.chores
  add constraint chores_extra_cents_check check (extra_cents >= 0);

alter table public.chore_completions
  add column if not exists cents_earned integer not null default 0,
  add column if not exists repeatable   boolean not null default false;

-- Was: unique (chore_id, due_on) for every row. Repeatable extras are the one
-- case where several completions on one key is the correct answer.
drop index if exists public.chore_completions_occurrence_uniq;
create unique index if not exists chore_completions_occurrence_uniq
  on public.chore_completions (chore_id, due_on)
  where not repeatable;

-- "How many times has this been done this week", the repeatable extras query.
create index if not exists chore_completions_chore_date_idx
  on public.chore_completions (chore_id, due_on);

-- ============================================================================
-- DONE. Verify the index is now partial — the predicate should be present:
--
--   select indexname, indexdef from pg_indexes
--    where tablename = 'chore_completions'
--      and indexname = 'chore_completions_occurrence_uniq';
--
-- And the new columns:
--
--   select title, kind, extra_cents, repeatable
--   from public.chores where kind = 'extra' order by title;
--
-- Pricing an extra by hand:
--
--   update public.chores
--      set extra_cents = 500, repeatable = false
--    where title = 'Mow the lawn';
-- ============================================================================
