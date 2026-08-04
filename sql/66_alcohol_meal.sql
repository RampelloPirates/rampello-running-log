-- ============================================================================
-- Alcohol as its own meal category
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- nutrition_entries.meal_type has allowed exactly four values since
-- 10_nutrition.sql. This adds a fifth.
--
-- WHY A CATEGORY AND NOT A FLAG
-- -----------------------------
-- A boolean would say "this entry was alcohol" while leaving it inside dinner,
-- and the whole point is to pull it out — to see the evening's food and the
-- evening's drink as separate figures rather than one number that hides the
-- split. Meal_type is already the axis the day is broken down by, so the
-- subdivision belongs there and every total, filter and grouping that reads
-- it picks the new value up without being told.
--
-- The cost is that it is exclusive: a glass of wine is alcohol OR dinner, not
-- both, and dinner's calorie figure no longer includes it. That is the
-- intended reading — the number you want from "dinner" is the food — but it
-- does mean a day's meals no longer sum the way they did before this existed.
--
-- WHY IT IS NEVER INFERRED
-- ------------------------
-- inferMeal() in nutrition.html guesses a meal from the clock for the entries
-- logged before meal_type was ever written, and it is deliberately not being
-- taught this value. There is no hour of the day that implies alcohol, and a
-- guess here would be a claim about someone's drinking invented by a clock.
-- Alcohol is only ever what you chose it to be.
-- ============================================================================

alter table public.nutrition_entries
  drop constraint if exists nutrition_entries_meal_type_check;

alter table public.nutrition_entries
  add constraint nutrition_entries_meal_type_check
  check (meal_type in ('breakfast', 'lunch', 'dinner', 'snack', 'alcohol'));

-- ============================================================================
-- DONE. Verify the constraint takes the new value and still refuses nonsense:
--
--   select conname, pg_get_constraintdef(oid)
--     from pg_constraint
--    where conname = 'nutrition_entries_meal_type_check';
--
-- Nothing is backfilled and nothing moves. Existing rows keep the meal_type
-- they had, including the null ones the app groups by inferring from the
-- clock — see the note above about why those are never inferred as alcohol.
--
-- Once you have logged a few, this is the split the category exists for:
--
--   select date_trunc('day', occurred_at)::date as day,
--          sum(total_calories) filter (where meal_type = 'alcohol') as from_drink,
--          sum(total_calories) filter (where meal_type is distinct from 'alcohol') as from_food,
--          sum(total_calories) as total
--     from public.nutrition_entries
--    group by 1 order by 1 desc limit 14;
-- ============================================================================
