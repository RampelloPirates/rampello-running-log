-- ============================================================================
-- A household recipe can point at one of your Nutrition recipes
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Nutrition already has recipes: foods rows with kind = 'recipe', carrying
-- per-100g macros, servings, finished weight and an ingredients array. Typing
-- "chicken tacos" a second time into the meal planner is silly when the real
-- version already exists with its ingredients worked out.
--
-- The complication is whose they are
-- ----------------------------------
-- foods.user_id is personal — one person's food diary, RLS scoped to
-- auth.uid(). recipes is household — everyone shares it. Joining across at
-- read time would mean the meal plan showing rows that only resolve for one
-- member and appear blank to everyone else, which is worse than not linking
-- at all.
--
-- So the link is a copy taken at the moment somebody acts, by the person who
-- owns both sides: importing reads YOUR nutrition recipe with YOUR
-- permissions and writes the name and ingredients onto the household row.
-- After that the household recipe stands on its own and reads correctly for
-- everyone, whatever happens to the personal one.
--
-- nutrition_food_id is kept anyway, as provenance rather than a dependency:
-- it lets the app offer "open this in Nutrition" to the one person for whom
-- that link resolves, and stays harmlessly unresolvable for everyone else. A
-- deleted food nulls it and the recipe is unaffected.
-- ============================================================================

alter table public.recipes
  add column if not exists nutrition_food_id uuid references public.foods(id) on delete set null;

create index if not exists recipes_nutrition_food_idx
  on public.recipes (nutrition_food_id) where nutrition_food_id is not null;

-- ============================================================================
-- DONE. Your own nutrition recipes, which are what the importer offers:
--
--   select id, name, servings, jsonb_array_length(coalesce(ingredients,'[]'::jsonb)) as ings
--   from public.foods where kind = 'recipe' order by name;
--
-- And which household recipes came from one:
--
--   select r.title, r.nutrition_food_id is not null as from_nutrition
--   from public.recipes r order by r.title;
--
-- Note the FK does not grant any read: another member can see that the column
-- is set and still cannot select the food it names. That's intended.
-- ============================================================================
