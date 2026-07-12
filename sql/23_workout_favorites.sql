-- ============================================================================
-- Workout favourites — a workout you liked, saved, and want to do again.
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- A favourite REMEMBERS the gym it came from, but isn't imprisoned by it. The
-- point is the opposite: when you add a new gym, the app checks whether that
-- gym can support your favourites and offers the ones it can. Your chest day
-- should follow you to the hotel if the hotel has the kit for it.
--
-- Which is why the exercises are stored with their equipment: matching a
-- favourite against a new gym's inventory needs to know what each movement
-- actually requires.
-- ============================================================================

create table if not exists public.workout_favorites (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  name          text not null,
  muscle_group  text not null,
  -- The gym it was born in. ON DELETE SET NULL: losing the gym doesn't lose the
  -- workout — that's the whole idea.
  origin_gym_id uuid references public.gyms(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index if not exists workout_favorites_user_idx
  on public.workout_favorites (user_id, created_at desc);

create table if not exists public.favorite_exercises (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  favorite_id  uuid not null references public.workout_favorites(id) on delete cascade,
  exercise     text not null,
  equipment    text,              -- what it needs — the key to matching a new gym
  position     integer not null default 0,
  created_at   timestamptz not null default now()
);

create index if not exists favorite_exercises_fav_idx
  on public.favorite_exercises (favorite_id, position);

alter table public.workout_favorites  enable row level security;
alter table public.favorite_exercises enable row level security;

drop policy if exists "own favorites" on public.workout_favorites;
create policy "own favorites" on public.workout_favorites
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own favorite exercises" on public.favorite_exercises;
create policy "own favorite exercises" on public.favorite_exercises
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- DONE. Verify:
--   select f.name, f.muscle_group, count(e.id) as exercises
--   from public.workout_favorites f
--   left join public.favorite_exercises e on e.favorite_id = f.id
--   group by f.id, f.name, f.muscle_group;
-- ============================================================================
