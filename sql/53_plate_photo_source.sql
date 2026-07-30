-- ============================================================================
-- A meal can now be logged from a photo of the plate
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- nutrition_entries.source records HOW a row got logged — typed and estimated,
-- read off a Nutrition Facts panel, scaled from a recipe, and so on. It is a
-- closed list, checked in the table, because the value is written by the app
-- and a typo there should fail loudly rather than quietly create a sixth kind
-- of entry nobody ever counts.
--
-- Photographing the food itself is a new way in, so the list grows by one.
--
-- Why 'plate' is its own source and not 'meal_parse'
-- --------------------------------------------------
-- Both end up in the same draft editor and both are model estimates, so it
-- would be tempting to reuse meal_parse. But they are wrong in different ways
-- and by different amounts: a typed meal is limited by how well you described
-- it, a photographed one by what the camera could see and what portion size
-- the model guessed. Keeping them apart is what makes it possible to ask later
-- whether the photo route is worth trusting — e.g. against the scale, in the
-- deficit model on the History tab. Collapsed into one source, that question
-- has no way to be asked.
-- ============================================================================

alter table public.nutrition_entries
  drop constraint if exists nutrition_entries_source_check;

alter table public.nutrition_entries
  add constraint nutrition_entries_source_check
  check (source in ('meal_parse','label','recipe','manual','barcode','usual','plate'));

-- ============================================================================
-- DONE. Verify the constraint took the new value:
--
--   select pg_get_constraintdef(oid)
--     from pg_constraint
--    where conname = 'nutrition_entries_source_check';
--
-- Existing rows are untouched — nothing that was valid before is invalid now,
-- which is why this needs no backfill and no downtime. Once the feature has
-- been used a few times, the mix reads:
--
--   select source, count(*), sum(total_calories)
--     from public.nutrition_entries group by source order by 2 desc;
-- ============================================================================
