-- ============================================================================
-- Strip leading gram amounts from nutrition entry titles
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- ============================================================================
--
-- Until the "amounts out of titles" change, logging a recipe portion titled the
-- entry with its weight glued to the front:
--
--     insertEntry({ title: grams + 'g ' + r.name, ... })   →  "250g Weeknight chili"
--
-- The Usuals tab is now derived from the log and dedupes by title, so one dish
-- eaten at three portion sizes shows up as three separate rows. This rewrites
-- the old titles to just the dish name; the weight is still on the entry's item
-- row, which is where the app now reads it from.
--
-- Scope — deliberately narrow, because most titles are prose you typed:
--
--   · source in ('recipe','usual') only. A 'meal_parse' title is your own
--     sentence ("2 eggs and toast"); stripping a number out of that would be
--     wrong, so those are left alone entirely.
--   · The pattern requires digits immediately followed by 'g' and a space —
--     "250g chili", never "250 g chili" — because that is exactly what the old
--     code emitted. Prose like "300 g flour" (with a space) won't match.
--
-- Idempotent: re-running changes nothing, because the pattern no longer matches
-- once stripped. Safe to run twice.
-- ============================================================================

-- NOTE ON auth.uid(): an earlier version of this file scoped every query to
-- `user_id = auth.uid()`. That is right for queries the app sends, and wrong
-- here — the SQL Editor connects as an admin role with no JWT, so auth.uid()
-- is NULL and every row fails the test. The queries below don't filter by user
-- at all. That's intentional: the old title format was a bug in shared code, so
-- every account that has it wants the same fix.

-- ---------------------------------------------------------------------------
-- STEP 0 — What have we got? Run this first; it tells you whether there is
-- anything to fix and rules out a silent mismatch.
-- ---------------------------------------------------------------------------
select
  (select count(*) from nutrition_entries)                                             as all_entries,
  (select count(*) from nutrition_entries
    where source in ('recipe','usual'))                                                as recipe_or_usual,
  (select count(*) from nutrition_entries
    where title ~ '^[0-9]+(\.[0-9]+)?g\s+')                                            as prefixed_any_source,
  (select count(*) from nutrition_entries
    where source in ('recipe','usual') and title ~ '^[0-9]+(\.[0-9]+)?g\s+')           as will_be_rewritten;

-- Reading it:
--   will_be_rewritten > 0            → step 1 will show you those rows. Carry on.
--   will_be_rewritten = 0 but
--     prefixed_any_source > 0        → the prefixed titles are on some OTHER source.
--                                      Run step 1b to see them before widening scope.
--   both 0                           → nothing to fix; your titles are already clean.

-- ---------------------------------------------------------------------------
-- STEP 1 — Preview. Every row here is a row step 2 will rewrite. If anything
-- in "new_title" looks wrong, stop and fix the pattern rather than running it.
-- ---------------------------------------------------------------------------
select
  id,
  log_date,
  source,
  title                                               as old_title,
  regexp_replace(title, '^[0-9]+(\.[0-9]+)?g\s+', '') as new_title
from nutrition_entries
where source in ('recipe', 'usual')
  and title ~ '^[0-9]+(\.[0-9]+)?g\s+'
order by log_date desc, occurred_at desc;

-- STEP 1b — only if step 0 says prefixed titles exist on other sources. Shows
-- what they are so you can decide, per source, whether they're machine-made
-- (safe to strip) or something you typed (leave alone).
-- select source, count(*), min(title) as example
-- from   nutrition_entries
-- where  title ~ '^[0-9]+(\.[0-9]+)?g\s+'
-- group  by source order by count(*) desc;

-- ---------------------------------------------------------------------------
-- STEP 2 — The rewrite. Run only after step 1 looks right.
-- Remove the leading "-- " from all four lines, then run just this block.
-- ---------------------------------------------------------------------------
-- update nutrition_entries
-- set    title = regexp_replace(title, '^[0-9]+(\.[0-9]+)?g\s+', '')
-- where  source in ('recipe', 'usual')
--   and  title ~ '^[0-9]+(\.[0-9]+)?g\s+';

-- ---------------------------------------------------------------------------
-- STEP 3 — Verify. still_prefixed should be 0 once step 2 has run.
-- ---------------------------------------------------------------------------
-- select count(*) as still_prefixed
-- from   nutrition_entries
-- where  source in ('recipe', 'usual')
--   and  title ~ '^[0-9]+(\.[0-9]+)?g\s+';
