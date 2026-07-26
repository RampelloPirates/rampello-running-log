-- ============================================================================
-- Allowance — points earned across the week, paid out in proportion
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- The design decision worth writing down is that kids never see a price on a
-- chore. Brushing your teeth is not worth fifty cents, and a child who has
-- worked out that it is will start declining the cheap ones. So chores carry
-- points, the week's points are totalled against a target, and the target is
-- what maps to money:
--
--     earned = points_this_week / points_target * base_allowance
--
-- Do everything and you get the whole allowance. Do most of it and you get
-- most of it. There is no per-chore rate to reverse-engineer, and the ratio
-- means adding a new chore doesn't silently inflate the payout — it just
-- makes the existing ones worth proportionally less of the same £/$ pot,
-- until you raise the target deliberately.
--
-- Points can exceed the target. That's the "add-on chores" case: extra work
-- above the routine pushes past 100% and pays above base, which is the whole
-- incentive for doing it.
--
-- Why points_earned is stored on the completion
-- ---------------------------------------------
-- Same denormalisation as workout_sets.exercise and meal_plan.title: the
-- value is captured when the thing happens. Otherwise re-pricing a chore, or
-- deleting one, silently rewrites what someone earned three weeks ago — and
-- the weekly total becomes a join against rows that may no longer exist or
-- may have been deactivated. As a plain sum it needs neither.
--
-- Overrides on the member are nullable and fall back to the household, so a
-- fourteen-year-old can be on a different deal from a seven-year-old without
-- either needing configuring by default.
-- ============================================================================

alter table public.households
  add column if not exists allowance_base_cents   integer not null default 1500,
  add column if not exists allowance_points_target integer not null default 500;

alter table public.households
  drop constraint if exists households_allowance_target_check;
alter table public.households
  add constraint households_allowance_target_check
  check (allowance_points_target > 0);

-- Null means "whatever the household says".
alter table public.household_members
  add column if not exists allowance_base_cents    integer,
  add column if not exists allowance_points_target integer;

alter table public.household_members
  drop constraint if exists household_members_allowance_target_check;
alter table public.household_members
  add constraint household_members_allowance_target_check
  check (allowance_points_target is null or allowance_points_target > 0);

alter table public.chore_completions
  add column if not exists points_earned integer not null default 0;

-- Backfill what's already been ticked off from the chore's current value —
-- the best guess available, and only wrong if a chore has been re-priced
-- since. Guarded so a second run can't double-apply or overwrite corrections.
update public.chore_completions cc
   set points_earned = c.points
  from public.chores c
 where c.id = cc.chore_id
   and cc.points_earned = 0
   and c.points > 0;

-- The weekly total's query: one member, one week.
create index if not exists chore_completions_member_week_idx
  on public.chore_completions (household_id, member_id, due_on);

-- ============================================================================
-- DONE. Verify the settings landed, and see what this week looks like.
-- NOTE the week starts MONDAY, which is not date_trunc's default for every
-- locale — date_trunc('week', ...) is ISO and starts Monday, which is what we
-- want here:
--
--   select name, allowance_base_cents, allowance_points_target
--   from public.households;
--
--   select m.display_name,
--          coalesce(sum(cc.points_earned), 0) as points_this_week
--   from public.household_members m
--   left join public.chore_completions cc
--          on cc.member_id = m.id
--         and cc.due_on >= date_trunc('week', current_date)::date
--   where m.active
--   group by m.display_name
--   order by m.display_name;
-- ============================================================================
