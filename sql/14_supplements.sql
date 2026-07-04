-- ============================================================================
-- Supplements — a daily checklist. Run in the Supabase SQL Editor.
--
-- Two tables, both per-user (individual use, like nutrition — scoped to
-- auth.uid()):
--   supplements     — your stack (name, dose, when). Soft-deleted via active.
--   supplement_log  — one row per supplement per day means "taken that day".
-- Safe to run more than once.
-- ============================================================================

create table if not exists public.supplements (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  dose        text,
  timing      text,                              -- e.g. 'Morning','Evening','Anytime'
  sort_order  integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.supplement_log (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  supplement_id uuid not null references public.supplements(id) on delete cascade,
  log_date      date not null,
  taken_at      timestamptz not null default now(),
  unique (supplement_id, log_date)              -- one check per supplement per day
);

create index if not exists supplements_user_idx on public.supplements (user_id) where active;
create index if not exists supplement_log_user_date_idx on public.supplement_log (user_id, log_date desc);

alter table public.supplements    enable row level security;
alter table public.supplement_log enable row level security;

drop policy if exists "own supplements" on public.supplements;
create policy "own supplements" on public.supplements
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own supplement_log" on public.supplement_log;
create policy "own supplement_log" on public.supplement_log
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- DONE. Verify:
--   select tablename from pg_tables where tablename like 'supplement%';
-- ============================================================================
