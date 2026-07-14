-- ============================================================================
-- 28 — Saved exercise menus
--
-- Asking Claude "what can I do for quads at the Y?" gives the same answer every
-- time, because the gym's equipment doesn't change between Tuesdays. Paying for
-- it (and waiting for it) on every visit is silly. Keep the menu.
--
-- One menu per (gym, muscle group). The fingerprint is the gym's equipment list
-- at the moment the menu was built — when the kit changes, the menu is stale and
-- the app says so rather than quietly serving a workout that no longer fits.
-- ============================================================================

create table if not exists public.gym_menus (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  gym_id          uuid not null references public.gyms(id) on delete cascade,
  muscle_group    text not null,
  groups          jsonb not null default '[]'::jsonb,
  note            text,
  kit_fingerprint text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- Regenerating a menu replaces it; you don't accumulate six versions of leg day.
create unique index if not exists gym_menus_one_per_muscle
  on public.gym_menus (gym_id, muscle_group);

alter table public.gym_menus enable row level security;

drop policy if exists "own gym_menus" on public.gym_menus;
create policy "own gym_menus" on public.gym_menus
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
