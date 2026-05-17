-- ============================================================================
-- Rampello Running Log — initial schema + RLS
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- ============================================================================
--
-- Design notes
-- ------------
-- * Segments are the atomic unit of a run. A "simple" log is one row in
--   run_segments; a "detailed" log (per-mile splits, mixed efforts) is many.
--   runs.distance_miles / runs.duration_seconds are kept in sync by the app
--   so list queries don't need a JOIN.
-- * Roster is the access list. Anyone whose email isn't in athletes or
--   coaches can authenticate but RLS gives them zero rows everywhere.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table athletes (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  first_name    text not null,
  last_name     text not null,
  email         text not null unique,
  grade         smallint check (grade between 3 and 8),
  gender        text check (gender in ('M','F','X')),
  joined_date   date not null default current_date,
  active        boolean not null default true,
  notes         text,
  created_at    timestamptz not null default now()
);

create table coaches (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  first_name    text not null,
  last_name     text not null,
  email         text not null unique,
  role          text not null default 'assistant' check (role in ('head','assistant')),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

create table runs (
  id                    uuid primary key default gen_random_uuid(),
  athlete_id            uuid not null references athletes(id) on delete cascade,
  run_date              date not null,
  time_of_day           text check (time_of_day in ('morning','afternoon','evening')),
  run_type              text not null check (run_type in (
                          'easy','long','tempo','intervals','race','cross_train'
                        )),
  distance_miles        numeric(5,2),
  duration_seconds      integer,
  avg_cadence           smallint check (avg_cadence between 100 and 250),
  avg_hr                smallint check (avg_hr between 30 and 240),
  max_hr                smallint check (max_hr between 30 and 240),
  effort_rpe            smallint check (effort_rpe between 1 and 10),
  route                 text,
  shoes                 text,
  conditions            text,                    -- e.g. "Clear", "Rain", "Humid"
  temperature_f         smallint,
  wind_mph              numeric(4,1),
  humidity_percent      smallint check (humidity_percent between 0 and 100),
  dewpoint_f            smallint,                 -- better "feels like" signal in Florida
  cross_train_activity  text,                    -- only used when run_type = 'cross_train'
  notes                 text,
  created_at            timestamptz not null default now(),
  created_by            uuid references auth.users(id),  -- who logged it (athlete or coach)
  check (run_type <> 'cross_train' or cross_train_activity is not null)
);

create table run_segments (
  id                   uuid primary key default gen_random_uuid(),
  run_id               uuid not null references runs(id) on delete cascade,
  segment_order        smallint not null,
  segment_type         text not null check (segment_type in (
                          'warmup','easy','tempo','threshold','interval','rest',
                          'hill','fartlek','strides','cooldown'
                        )),
  distance_miles       numeric(5,2),
  duration_seconds     integer,
  target_pace_seconds  integer,
  avg_cadence          smallint check (avg_cadence between 100 and 250),
  avg_hr               smallint check (avg_hr between 30 and 240),
  max_hr               smallint check (max_hr between 30 and 240),
  notes                text,
  unique (run_id, segment_order)
);

create table race_results (
  id                        uuid primary key default gen_random_uuid(),
  run_id                    uuid not null unique references runs(id) on delete cascade,
  meet_name                 text not null,
  course_name               text,
  course_type               text check (course_type in ('xc','track','road')),
  official_distance_meters  integer,
  finish_place_overall      integer,
  finish_place_team         integer,
  team_score_total          integer,
  opponents                 text,
  conditions_notes          text,
  created_at                timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

create index runs_athlete_date_idx on runs (athlete_id, run_date desc);
create index runs_run_date_idx     on runs (run_date desc);
create index runs_type_idx         on runs (run_type);
create index run_segments_run_idx  on run_segments (run_id, segment_order);
create index athletes_active_idx   on athletes (active) where active = true;

-- ---------------------------------------------------------------------------
-- Auth linking trigger.
-- New auth.users row → look up the email in athletes / coaches → set
-- auth_user_id. This is what restricts sign-in to the pre-provisioned roster.
-- ---------------------------------------------------------------------------

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

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.link_auth_user_to_roster();

-- ---------------------------------------------------------------------------
-- is_coach() helper used by RLS policies. SECURITY DEFINER bypasses RLS on
-- the coaches table so the policy doesn't recurse.
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

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table athletes     enable row level security;
alter table coaches      enable row level security;
alter table runs         enable row level security;
alter table run_segments enable row level security;
alter table race_results enable row level security;

-- athletes ------------------------------------------------------------------

create policy "athlete sees self" on athletes
  for select using (auth_user_id = auth.uid());

create policy "athlete updates self" on athletes
  for update using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

create policy "coach reads all athletes" on athletes
  for select using (public.is_coach());

create policy "coach inserts athletes" on athletes
  for insert with check (public.is_coach());

create policy "coach updates athletes" on athletes
  for update using (public.is_coach()) with check (public.is_coach());

create policy "coach deletes athletes" on athletes
  for delete using (public.is_coach());

-- coaches -------------------------------------------------------------------
-- Both head and assistant coaches can manage the coach roster.

create policy "coach reads coaches" on coaches
  for select using (public.is_coach());

create policy "coach inserts coaches" on coaches
  for insert with check (public.is_coach());

create policy "coach updates coaches" on coaches
  for update using (public.is_coach()) with check (public.is_coach());

create policy "coach deletes coaches" on coaches
  for delete using (public.is_coach());

-- runs ----------------------------------------------------------------------
-- Athletes own their runs. Coaches have full read/write so they can do
-- bulk uploads on workout days and fix typos.

create policy "athlete owns runs" on runs
  for all
  using     (athlete_id in (select id from athletes where auth_user_id = auth.uid()))
  with check(athlete_id in (select id from athletes where auth_user_id = auth.uid()));

create policy "coach manages runs" on runs
  for all using (public.is_coach()) with check (public.is_coach());

-- run_segments (ownership follows runs) -------------------------------------

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

create policy "coach manages segments" on run_segments
  for all using (public.is_coach()) with check (public.is_coach());

-- race_results (ownership follows runs) -------------------------------------

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

create policy "coach manages race results" on race_results
  for all using (public.is_coach()) with check (public.is_coach());

-- ============================================================================
-- DONE. Next, seed the head coach so first sign-in works (replace email):
--
--   insert into coaches (first_name, last_name, email, role)
--   values ('HEAD COACH FIRST', 'HEAD COACH LAST', 'head-coach-email@example.com', 'head');
--
-- And seed yourself as assistant:
--
--   insert into coaches (first_name, last_name, email, role)
--   values ('Jeff', 'Smith', 'your-personal-email@example.com', 'assistant');
-- ============================================================================
