-- ============================================================================
-- Goals for the macros, not just the calories
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- nutrition_settings has carried exactly one number since 10_nutrition.sql: a
-- daily calorie target. The Today card has shown protein, fat, carbs and fiber
-- all along, but only ever as totals — four numbers with nothing to be measured
-- against, which makes them a readout rather than a goal. These four columns
-- are what turn them into one.
--
-- Why four nullable columns and not a jsonb blob
-- ----------------------------------------------
-- The set is closed and it is the same set the entries table already spells out
-- as columns (protein, fat, carbs, fiber). Matching that shape means a target
-- can be compared to an intake without unpacking anything, and a typo in a key
-- name fails at the database rather than silently reading as "no goal". jsonb
-- would only earn its keep if the macros were open-ended, and they are not.
--
-- All four are nullable and independently so. Setting a protein goal and
-- leaving the rest blank is the common case — it is the one macro most people
-- actually aim at — and a null reads as "no goal for this one", which is what
-- the card renders as a plain total exactly like today.
-- ============================================================================

alter table public.nutrition_settings
  add column if not exists protein_target integer
    check (protein_target is null or protein_target > 0),
  add column if not exists fat_target     integer
    check (fat_target     is null or fat_target     > 0),
  add column if not exists carbs_target   integer
    check (carbs_target   is null or carbs_target   > 0),
  add column if not exists fiber_target   integer
    check (fiber_target   is null or fiber_target   > 0);

-- ============================================================================
-- DONE. Verify the columns landed:
--
--   select column_name, data_type, is_nullable
--     from information_schema.columns
--    where table_name = 'nutrition_settings'
--    order by ordinal_position;
--
-- Existing rows are untouched and read fine with all four null — the macro
-- cells render as the bare totals they have always been:
--
--   select calorie_target, protein_target, fat_target, carbs_target, fiber_target
--     from public.nutrition_settings;
--
-- No RLS change is needed. The "own settings" policy from 10_nutrition.sql is
-- written against the row (user_id = auth.uid()), not against a column list,
-- so it covers these the moment they exist.
-- ============================================================================
