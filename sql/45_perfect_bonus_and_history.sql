-- ============================================================================
-- Perfect-week bonus, an audit trail on completions, and closing the week
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Three things that belong together, because they're all about the week being
-- something you settle up on Monday rather than a rolling total.
--
-- 1. The bonus, and why it's a percentage
-- ---------------------------------------
-- "490 points gets another $5" is exactly right for a kid whose target is
-- 500 and impossible for one whose target is 300 — and targets are already
-- per member. Stored as a percentage, 98% is 490 of 500 and 294 of 300, and
-- nobody has to remember to re-set a second number when they raise a target.
-- The app shows the resulting points figure, so it still reads as "490".
--
-- 2. Who actually ticked it
-- -------------------------
-- member_id is who the points go to, which is the chore's assignee — a parent
-- ticking Emma's chore off the wall still pays Emma. That deliberately loses
-- who did the tapping, which is the thing you want when a total looks wrong.
-- completed_by records it. completed_at already existed.
--
-- 3. Closing the week
-- -------------------
-- Once the week is paid it has to stop moving, or Monday's number isn't the
-- number you paid. Kids can only touch the current pay week; adults can
-- correct anything, because "I forgot to tick Thursday" is a real thing that
-- happens and someone has to be able to fix it.
--
-- Enforced here rather than by hiding buttons: the app can only decline to
-- show a control, and the row is one fetch call away regardless.
-- date_trunc('week') is ISO — it starts Monday, which is the pay week.
-- ============================================================================

alter table public.households
  add column if not exists perfect_bonus_pct   integer not null default 98,
  add column if not exists perfect_bonus_cents integer not null default 500;

alter table public.households
  drop constraint if exists households_bonus_pct_check;
alter table public.households
  add constraint households_bonus_pct_check
  check (perfect_bonus_pct between 1 and 100);

-- Null means "whatever the household says", as with the other overrides.
alter table public.household_members
  add column if not exists perfect_bonus_pct   integer,
  add column if not exists perfect_bonus_cents integer;

alter table public.household_members
  drop constraint if exists household_members_bonus_pct_check;
alter table public.household_members
  add constraint household_members_bonus_pct_check
  check (perfect_bonus_pct is null or perfect_bonus_pct between 1 and 100);

-- Who tapped, as opposed to who gets paid.
alter table public.chore_completions
  add column if not exists completed_by uuid references public.household_members(id) on delete set null;

-- Reviewing a past week reads by household and date.
create index if not exists chore_completions_week_idx
  on public.chore_completions (household_id, due_on desc);

-- ── Adults ─────────────────────────────────────────────────────────────────
-- Admins can already do everything; this is the wider "old enough to correct
-- last week" test. SECURITY DEFINER for the same recursion reason as the rest.
create or replace function public.is_household_adult(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hid and m.user_id = auth.uid()
      and m.active = true and m.role in ('admin','adult')
  );
$$;

grant execute on function public.is_household_adult(uuid) to authenticated;

-- ── RLS: the past is read-only for kids ────────────────────────────────────
-- Replaces the single FOR ALL policy, which let anyone in the household
-- rewrite any week.
drop policy if exists "household chore completions" on public.chore_completions;

drop policy if exists "completions read" on public.chore_completions;
create policy "completions read" on public.chore_completions
  for select using (public.is_household_member(household_id));

drop policy if exists "completions insert" on public.chore_completions;
create policy "completions insert" on public.chore_completions
  for insert to authenticated with check (
    public.is_household_member(household_id)
    and (public.is_household_adult(household_id)
         or due_on >= date_trunc('week', current_date)::date)
  );

drop policy if exists "completions update" on public.chore_completions;
create policy "completions update" on public.chore_completions
  for update using (
    public.is_household_member(household_id)
    and (public.is_household_adult(household_id)
         or due_on >= date_trunc('week', current_date)::date)
  ) with check (
    public.is_household_member(household_id)
    and (public.is_household_adult(household_id)
         or due_on >= date_trunc('week', current_date)::date)
  );

drop policy if exists "completions delete" on public.chore_completions;
create policy "completions delete" on public.chore_completions
  for delete using (
    public.is_household_member(household_id)
    and (public.is_household_adult(household_id)
         or due_on >= date_trunc('week', current_date)::date)
  );

-- ============================================================================
-- DONE. Verify the four policies replaced the one:
--
--   select policyname, cmd from pg_policies
--    where tablename = 'chore_completions' order by cmd;
--
-- Last week's settle-up, which is what Monday morning is for:
--
--   select m.display_name,
--          sum(cc.points_earned) as points,
--          sum(cc.cents_earned)  as extra_cents
--     from public.chore_completions cc
--     join public.household_members m on m.id = cc.member_id
--    where cc.due_on >= (date_trunc('week', current_date) - interval '7 days')::date
--      and cc.due_on <  date_trunc('week', current_date)::date
--    group by m.display_name order by m.display_name;
--
-- And the audit trail, when a total looks wrong:
--
--   select c.title, cc.due_on, cc.completed_at,
--          paid.display_name as credited, tapper.display_name as marked_by
--     from public.chore_completions cc
--     join public.chores c on c.id = cc.chore_id
--     left join public.household_members paid   on paid.id = cc.member_id
--     left join public.household_members tapper on tapper.id = cc.completed_by
--    order by cc.completed_at desc limit 50;
-- ============================================================================
