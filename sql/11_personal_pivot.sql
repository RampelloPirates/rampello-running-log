-- ============================================================================
-- Personal-health pivot — remove the coach/athlete team structure
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- ============================================================================
--
-- The app is moving from a team XC tool to an individual health database.
-- After this migration there are no coaches, no shared roster, no public
-- parent signup, and no team leaderboard. Every auth user is a single runner
-- who owns their own runs; their profile row in `athletes` is auto-created by
-- the app on first sign-in (self-provisioning).
--
-- Per decision: existing data is WIPED for a clean start.
-- Deploy together with the matching front-end (auth.js + pages) — running this
-- while the old coach-aware pages are live would break them.
-- Safe to run more than once.
-- ============================================================================

-- ── 1. Drop the coach layer ─────────────────────────────────────────────────
-- Dropping is_coach() with CASCADE also drops every RLS policy that calls it
-- (all the "coach ..." policies across athletes/coaches/runs/run_segments/
-- race_results/pace_targets), so those don't need to be dropped one by one.
drop function if exists public.is_coach() cascade;
drop table    if exists public.coaches cascade;

-- ── 2. Drop the roster-link trigger + public self-signup ────────────────────
drop trigger  if exists on_auth_user_created on auth.users;
drop function if exists public.link_auth_user_to_roster();
drop policy   if exists "anon can self signup" on public.athletes;

-- ── 3. Drop the team leaderboard aggregate (leaderboard page is removed) ─────
drop function if exists public.team_leaderboard(date, date);

-- ── 4. Wipe existing data — clean start ─────────────────────────────────────
-- Cascades through runs → run_segments / race_results and pace_targets.
truncate table public.athletes cascade;

-- ── 5. Personal RLS ─────────────────────────────────────────────────────────
-- athletes: the original "athlete sees self" / "athlete updates self" policies
-- already scope to the user's own row. Add insert so the app can create the
-- user's profile on first sign-in.
drop policy if exists "user provisions self" on public.athletes;
create policy "user provisions self" on public.athletes
  for insert to authenticated
  with check (auth_user_id = auth.uid());

-- pace_targets: recreate cleanly in the per-athlete shape the front-end uses,
-- with a self-manage policy. Dropped + recreated (rather than ALTERed) so this
-- works regardless of the table's current shape on this database — some
-- environments still have the older team-wide pace_targets with no athlete_id.
drop table if exists public.pace_targets cascade;
create table public.pace_targets (
  athlete_id     uuid not null references public.athletes(id) on delete cascade,
  category       text not null check (category in ('easy','tempo','race')),
  target_seconds integer check (target_seconds between 120 and 1800),  -- 2:00–30:00 /mi
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id),
  primary key (athlete_id, category)
);
alter table public.pace_targets enable row level security;
create policy "athlete owns pace targets" on public.pace_targets
  for all
  using     (athlete_id in (select id from public.athletes where auth_user_id = auth.uid()))
  with check (athlete_id in (select id from public.athletes where auth_user_id = auth.uid()));

-- runs / run_segments / race_results keep their existing "athlete owns ..."
-- policies, which already scope per-user. Nothing to add.

-- ============================================================================
-- DONE. Verify the coach layer is gone:
--   select to_regclass('public.coaches');                          -- null
--   select to_regproc('public.is_coach');                          -- null
--   select polname, tablename from pg_policies
--     where schemaname='public' and polname ilike '%coach%';       -- 0 rows
--   select polname, tablename from pg_policies
--     where schemaname='public' order by tablename, polname;
-- ============================================================================
