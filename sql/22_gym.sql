-- ============================================================================
-- Gym — inventory the gyms you actually train at, then get exercises you can
-- actually do there, and log the sets you actually did.
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- The shape of the thing:
--   gyms              — a place you train (home garage, the Y, a hotel gym)
--   gym_equipment     — what's in it. Photographed and read by Claude, then
--                       hand-correctable. This is the constraint that makes the
--                       exercise suggestions honest: no cable machine, no cable
--                       exercises.
--   workout_sessions  — one visit: a gym, a day, a muscle group
--   workout_sets      — one set: exercise, reps, weight. The actual history.
--
-- Sets hang off a session (not off an exercise catalogue) on purpose: exercises
-- are generated per gym per muscle group, so there's no stable exercise table to
-- point at. The exercise NAME is denormalised onto the set, which is what you
-- want anyway — "Incline DB press, 3×8 @ 55" should still read correctly in two
-- years even if the gym is gone and the generator has changed its mind.
-- ============================================================================

-- ── A place you train ──────────────────────────────────────────────────────
create table if not exists public.gyms (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  note        text,
  is_default  boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists gyms_user_idx on public.gyms (user_id, created_at desc);

-- ── What's in it ───────────────────────────────────────────────────────────
-- `category` buckets the menu in the UI (free weights / machines / cables /
-- bodyweight / cardio). `detail` carries the thing that decides whether an
-- exercise is possible: "dumbbells 5–50 lb", "no safety bars".
create table if not exists public.gym_equipment (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  gym_id      uuid not null references public.gyms(id) on delete cascade,
  name        text not null,
  category    text,
  detail      text,
  created_at  timestamptz not null default now()
);

-- The same rack photographed twice from two angles shouldn't become two racks.
create unique index if not exists gym_equipment_dedupe
  on public.gym_equipment (gym_id, lower(name));

create index if not exists gym_equipment_gym_idx on public.gym_equipment (gym_id);

-- ── One visit ──────────────────────────────────────────────────────────────
create table if not exists public.workout_sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  gym_id        uuid references public.gyms(id) on delete set null,
  worked_on     date not null default current_date,
  muscle_group  text not null,
  note          text,
  finished_at   timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists workout_sessions_user_idx
  on public.workout_sessions (user_id, worked_on desc);

-- ── One set ────────────────────────────────────────────────────────────────
-- weight is nullable: bodyweight exercises have none, and "3 sets of pull-ups"
-- is a real, complete record.
create table if not exists public.workout_sets (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  session_id  uuid not null references public.workout_sessions(id) on delete cascade,
  exercise    text not null,
  equipment   text,
  set_no      integer not null default 1,
  reps        integer,
  weight      numeric,
  unit        text not null default 'lb',
  created_at  timestamptz not null default now()
);

create index if not exists workout_sets_session_idx on public.workout_sets (session_id, created_at);
-- "What did I press last time?" — the query that makes logging worth doing.
create index if not exists workout_sets_user_exercise_idx
  on public.workout_sets (user_id, lower(exercise), created_at desc);

-- ── RLS: everything is your own ────────────────────────────────────────────
alter table public.gyms             enable row level security;
alter table public.gym_equipment    enable row level security;
alter table public.workout_sessions enable row level security;
alter table public.workout_sets     enable row level security;

drop policy if exists "own gyms" on public.gyms;
create policy "own gyms" on public.gyms
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own gym equipment" on public.gym_equipment;
create policy "own gym equipment" on public.gym_equipment
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own workout sessions" on public.workout_sessions;
create policy "own workout sessions" on public.workout_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own workout sets" on public.workout_sets;
create policy "own workout sets" on public.workout_sets
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- DONE. Verify:
--   select g.name, count(e.id) as equipment
--   from public.gyms g left join public.gym_equipment e on e.gym_id = g.id
--   group by g.name;
-- ============================================================================
