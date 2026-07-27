-- ============================================================================
-- Recipes get the rest of what a recipe is
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Until now a "recipe" here has been an ingredient list with the macro maths
-- done on it — enough to log a portion, not enough to cook from. foods rows
-- with kind = 'recipe' carry per-100g nutrition, a finished weight, servings
-- and the ingredients array, and nothing at all about what to DO with them.
-- recipes.html is the page that finally reads like a recipe card, so the
-- columns it needs land here.
--
-- Why these live on `foods` rather than a new recipes table
-- --------------------------------------------------------
-- There is already one recipe store per side of the privacy line: foods
-- (personal, RLS to auth.uid()) and public.recipes (household, RLS to
-- membership), joined by the copy-at-action-time pattern set out in
-- 51_recipe_nutrition_link. A third table would mean a third thing to keep in
-- step and a second answer to "which one is the real one". So the new page
-- reads and writes the rows the calorie tracker already logs portions from.
--
-- instructions is text, not an array of steps
-- -------------------------------------------
-- Steps get typed, pasted and scraped, and the shapes never agree: some sites
-- give one paragraph, some give twelve numbered lines, some nest sections
-- ("For the sauce…"). Storing text keeps every one of those intact and lets
-- the page render on blank lines. An array would force a parse at write time
-- and lose whatever didn't fit — and nothing in the app ever needs to address
-- step 4 on its own.
-- ============================================================================

-- ── The personal side: foods (kind = 'recipe') ─────────────────────────────
alter table public.foods
  add column if not exists instructions   text,
  -- Where it was scraped from. Provenance, and the link back for the details
  -- no importer gets right — the photo, the comments, the story above it.
  add column if not exists source_url     text,
  -- One number, not prep + cook. The split is a magazine convention and gets
  -- guessed at on entry; "about 40 minutes" is the part you actually plan
  -- around, and it's the one figure the scraper can read reliably.
  add column if not exists total_minutes  integer
    check (total_minutes is null or total_minutes > 0);

-- ── The household side: recipes ────────────────────────────────────────────
-- 51 made the copy go both ways, carrying the name and the ingredients. Steps
-- would have dropped silently on the way across, which is the sort of quiet
-- loss you only notice standing at the hob. Same column, same reasoning.
alter table public.recipes
  add column if not exists instructions text;

-- ============================================================================
-- Search is deliberately NOT indexed here
--
-- The page searches your recipes by title and by ingredient name, and does it
-- in the browser over rows it has already loaded — which is every recipe you
-- own, because the ingredient library needs them all anyway. At the scale of
-- a household recipe box that is one keystroke's work and no round trip, and
-- it matches by ingredient without teaching Postgres to search inside a jsonb
-- array. If this ever grows past a few hundred recipes, the answer is a
-- generated tsvector over (name, ingredients) with a GIN index — not a
-- like-scan pretending to be search.
-- ============================================================================

-- ============================================================================
-- DONE. Verify the columns landed:
--
--   select column_name, data_type from information_schema.columns
--    where table_name = 'foods'
--      and column_name in ('instructions','source_url','total_minutes');
--
--   select column_name from information_schema.columns
--    where table_name = 'recipes' and column_name = 'instructions';
--
-- Existing recipes are untouched and read fine with all three null — the page
-- shows an ingredient list and no method, which is exactly what those rows
-- have always been:
--
--   select name, servings, total_minutes,
--          instructions is not null as has_method,
--          jsonb_array_length(coalesce(ingredients,'[]'::jsonb)) as ings
--     from public.foods where kind = 'recipe' order by name;
-- ============================================================================
