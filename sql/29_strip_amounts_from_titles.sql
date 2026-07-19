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

-- ---------------------------------------------------------------------------
-- STEP 1 — Preview. Run this ALONE first and read the output.
-- Every row it returns is a row step 2 will rewrite. If anything in "new_title"
-- looks wrong, stop and fix the pattern rather than running step 2.
-- ---------------------------------------------------------------------------
select
  id,
  log_date,
  source,
  title                                            as old_title,
  regexp_replace(title, '^[0-9]+(\.[0-9]+)?g\s+', '') as new_title
from nutrition_entries
where user_id = auth.uid()
  and source in ('recipe', 'usual')
  and title ~ '^[0-9]+(\.[0-9]+)?g\s+'
order by log_date desc, occurred_at desc;

-- ---------------------------------------------------------------------------
-- STEP 2 — The rewrite. Run only after step 1 looks right.
-- ---------------------------------------------------------------------------
-- update nutrition_entries
-- set    title = regexp_replace(title, '^[0-9]+(\.[0-9]+)?g\s+', '')
-- where  user_id = auth.uid()
--   and  source in ('recipe', 'usual')
--   and  title ~ '^[0-9]+(\.[0-9]+)?g\s+';

-- ---------------------------------------------------------------------------
-- STEP 3 — Verify. Should return zero rows once step 2 has run.
-- ---------------------------------------------------------------------------
-- select count(*) as still_prefixed
-- from   nutrition_entries
-- where  user_id = auth.uid()
--   and  source in ('recipe', 'usual')
--   and  title ~ '^[0-9]+(\.[0-9]+)?g\s+';
