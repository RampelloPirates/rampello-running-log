-- ============================================================================
-- Vitals — blood pressure, weight, pulse, temperature, height over time. Run in
-- the Supabase SQL Editor. Safe to run more than once.
--
-- One table, per-user (scoped to auth.uid()). One row per reading:
--   kind    — 'blood_pressure' | 'weight' | 'pulse' | 'temperature' | 'height'
--   value   — the reading (systolic for BP; the number otherwise)
--   value2  — diastolic, for blood_pressure only
--
-- Seeded from the BayCare portal PDFs by labs_sync/import_labs.py (which pulls
-- vitals alongside labs), and hand-editable in vitals.html. Reference ranges for
-- vitals are universal, so the app hardcodes them rather than storing them here.
-- ============================================================================

create table if not exists public.vitals (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  measured_on  date not null,
  kind         text not null,
  value        numeric,
  value2       numeric,                          -- diastolic (blood_pressure only)
  unit         text,
  source       text,                             -- 'BayCare (portal)', 'Manual', …
  import_ref   text,                             -- 'portalv:<date>:<kind>' — dedup key
  notes        text,
  created_at   timestamptz not null default now(),
  unique (user_id, import_ref)
);

create index if not exists vitals_user_kind_date_idx on public.vitals (user_id, kind, measured_on desc);

alter table public.vitals enable row level security;

drop policy if exists "own vitals" on public.vitals;
create policy "own vitals" on public.vitals
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- DONE. Verify:  select kind, count(*) from public.vitals group by kind;
-- ============================================================================
