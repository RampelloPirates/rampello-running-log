-- ============================================================================
-- Meal plan — what's for dinner, against the week you've actually got
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
--   recipes    — things you cook, with somewhere to put the link
--   meal_plan  — one meal on one day. Freeform by default; a recipe optionally
--                attached.
--
-- Why the title is stored even when a recipe is linked
-- ---------------------------------------------------
-- Same reasoning as workout_sets.exercise in 22_gym: the name is denormalised
-- onto the row because that's what you actually want. "Tuesday: chicken tacos"
-- should still read correctly in two years whether or not the recipe survived,
-- and it means deleting a recipe can simply null the link instead of either
-- cascading away your meal history or leaving a row that renders as blank.
--
-- It also avoids a genuinely awkward constraint. Had the title been optional
-- with "recipe_id or title must be set", deleting a recipe would fire ON
-- DELETE SET NULL into a row that then violates its own check — and the delete
-- fails for reasons nobody would enjoy diagnosing.
--
-- venue is separate from the meal because eating out is still a plan for that
-- evening, not an absence of one — the wall should be able to say "Friday:
-- out" rather than showing Friday empty.
-- ============================================================================

create table if not exists public.recipes (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  title         text not null,
  source_url    text,
  ingredients   text,
  notes         text,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index if not exists recipes_household_idx
  on public.recipes (household_id, lower(title));

create table if not exists public.meal_plan (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  plan_date     date not null,
  slot          text not null default 'dinner'
                  check (slot in ('breakfast','lunch','dinner')),
  -- Always populated. Copied from the recipe when you pick one, and editable
  -- afterwards, because "tacos (double it, Sam's staying)" is the useful
  -- version of the plan.
  title         text not null,
  -- A soft link: nulled if the recipe goes, leaving the meal intact.
  recipe_id     uuid references public.recipes(id) on delete set null,
  venue         text not null default 'eat_in'
                  check (venue in ('eat_in','eat_out','at_friends')),
  notes         text,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

-- The week view's query, and the order it wants them in.
create index if not exists meal_plan_household_date_idx
  on public.meal_plan (household_id, plan_date, slot);

-- ── RLS: membership, same as everything else household-scoped ──────────────
alter table public.recipes   enable row level security;
alter table public.meal_plan enable row level security;

drop policy if exists "household recipes" on public.recipes;
create policy "household recipes" on public.recipes
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

drop policy if exists "household meal plan" on public.meal_plan;
create policy "household meal plan" on public.meal_plan
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

-- ============================================================================
-- DONE. Verify:
--
--   select plan_date, slot, title, venue from public.meal_plan
--   order by plan_date, slot;
--
-- Check the soft link behaves — deleting a recipe should leave the meal
-- readable with a null recipe_id, not remove it:
--
--   -- delete from public.recipes where id = '<some id>';
--   -- select title, recipe_id from public.meal_plan where title = '...';
-- ============================================================================
