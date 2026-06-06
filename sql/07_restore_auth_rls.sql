-- ============================================================================
-- Rampello Running Log — restore real auth + RLS (reverses 04_open_access.sql)
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- ============================================================================
--
-- Why
-- ---
-- 04_open_access.sql dropped every RLS policy and disabled RLS so the app could
-- run as an open demo (identity picked from a dropdown). We're now going live
-- with real per-kid magic-link / OTP auth, so this re-enables RLS and re-creates
-- the original policies. After this runs, the public anon key alone can read
-- nothing — every request is scoped to the signed-in user.
--
-- Safe to run more than once (drops policies if they exist before creating).
-- Deploy this together with the auth-enabled front-end: enabling RLS while the
-- pages still use the demo model would lock everyone out.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helpers (re-asserted idempotently; 04 left these in place, but be safe).
-- ---------------------------------------------------------------------------

create or replace function public.is_coach()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.coaches
    where auth_user_id = auth.uid() and active = true
  );
$$;

create or replace function public.link_auth_user_to_roster()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.athletes
    set auth_user_id = new.id
    where lower(email) = lower(new.email) and auth_user_id is null;

  update public.coaches
    set auth_user_id = new.id
    where lower(email) = lower(new.email) and auth_user_id is null;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.link_auth_user_to_roster();

-- ---------------------------------------------------------------------------
-- Re-enable Row Level Security
-- ---------------------------------------------------------------------------

alter table athletes     enable row level security;
alter table coaches      enable row level security;
alter table runs         enable row level security;
alter table run_segments enable row level security;
alter table race_results enable row level security;

-- athletes ------------------------------------------------------------------

drop policy if exists "athlete sees self"        on athletes;
create policy "athlete sees self" on athletes
  for select using (auth_user_id = auth.uid());

drop policy if exists "athlete updates self"     on athletes;
create policy "athlete updates self" on athletes
  for update using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

drop policy if exists "coach reads all athletes"  on athletes;
create policy "coach reads all athletes" on athletes
  for select using (public.is_coach());

drop policy if exists "coach inserts athletes"    on athletes;
create policy "coach inserts athletes" on athletes
  for insert with check (public.is_coach());

drop policy if exists "coach updates athletes"    on athletes;
create policy "coach updates athletes" on athletes
  for update using (public.is_coach()) with check (public.is_coach());

drop policy if exists "coach deletes athletes"    on athletes;
create policy "coach deletes athletes" on athletes
  for delete using (public.is_coach());

-- coaches -------------------------------------------------------------------

drop policy if exists "coach reads coaches"       on coaches;
create policy "coach reads coaches" on coaches
  for select using (public.is_coach());

drop policy if exists "coach inserts coaches"     on coaches;
create policy "coach inserts coaches" on coaches
  for insert with check (public.is_coach());

drop policy if exists "coach updates coaches"     on coaches;
create policy "coach updates coaches" on coaches
  for update using (public.is_coach()) with check (public.is_coach());

drop policy if exists "coach deletes coaches"     on coaches;
create policy "coach deletes coaches" on coaches
  for delete using (public.is_coach());

-- runs ----------------------------------------------------------------------

drop policy if exists "athlete owns runs"         on runs;
create policy "athlete owns runs" on runs
  for all
  using     (athlete_id in (select id from athletes where auth_user_id = auth.uid()))
  with check(athlete_id in (select id from athletes where auth_user_id = auth.uid()));

drop policy if exists "coach manages runs"        on runs;
create policy "coach manages runs" on runs
  for all using (public.is_coach()) with check (public.is_coach());

-- run_segments (ownership follows runs) -------------------------------------

drop policy if exists "athlete owns segments"     on run_segments;
create policy "athlete owns segments" on run_segments
  for all
  using (run_id in (
    select r.id from runs r
    join athletes a on a.id = r.athlete_id
    where a.auth_user_id = auth.uid()
  ))
  with check (run_id in (
    select r.id from runs r
    join athletes a on a.id = r.athlete_id
    where a.auth_user_id = auth.uid()
  ));

drop policy if exists "coach manages segments"    on run_segments;
create policy "coach manages segments" on run_segments
  for all using (public.is_coach()) with check (public.is_coach());

-- race_results (ownership follows runs) -------------------------------------

drop policy if exists "athlete owns race results" on race_results;
create policy "athlete owns race results" on race_results
  for all
  using (run_id in (
    select r.id from runs r
    join athletes a on a.id = r.athlete_id
    where a.auth_user_id = auth.uid()
  ))
  with check (run_id in (
    select r.id from runs r
    join athletes a on a.id = r.athlete_id
    where a.auth_user_id = auth.uid()
  ));

drop policy if exists "coach manages race results" on race_results;
create policy "coach manages race results" on race_results
  for all using (public.is_coach()) with check (public.is_coach());

-- ---------------------------------------------------------------------------
-- Team leaderboard aggregate (SECURITY DEFINER).
--
-- The "athlete owns runs" policy means a kid can only SELECT their own runs, so
-- a client-side team leaderboard would show only themselves. This function runs
-- as the owner (bypassing RLS) but returns only non-sensitive aggregates — name,
-- grade, total mileage/time, and days logged — for a date window. cross_train is
-- excluded to match the leaderboard's product rule. Any signed-in user may call
-- it; nothing row-level or contact-related is exposed.
-- ---------------------------------------------------------------------------

create or replace function public.team_leaderboard(p_start date, p_end date)
returns table (
  athlete_id    uuid,
  first_name    text,
  last_name     text,
  grade         smallint,
  total_miles   numeric,
  total_seconds bigint,
  days_logged   bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id,
    a.first_name,
    a.last_name,
    a.grade,
    coalesce(sum(r.distance_miles), 0)::numeric  as total_miles,
    coalesce(sum(r.duration_seconds), 0)::bigint as total_seconds,
    count(distinct r.run_date)                   as days_logged
  from public.athletes a
  join public.runs r on r.athlete_id = a.id
  where a.active = true
    and r.run_type <> 'cross_train'
    and r.run_date >= p_start
    and r.run_date <= p_end
  group by a.id, a.first_name, a.last_name, a.grade
  having coalesce(sum(r.distance_miles), 0) > 0
      or coalesce(sum(r.duration_seconds), 0) > 0;
$$;

revoke all on function public.team_leaderboard(date, date) from public;
grant execute on function public.team_leaderboard(date, date) to authenticated;

-- ============================================================================
-- DONE. Verify with:
--   select tablename, rowsecurity from pg_tables
--     where schemaname='public' order by tablename;        -- all true
--   select polname, tablename from pg_policies
--     where schemaname='public' order by tablename, polname;
-- ============================================================================
