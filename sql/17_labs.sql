-- ============================================================================
-- Lab results — bloodwork & other lab panels over time. Run in the Supabase
-- SQL Editor. Safe to run more than once.
--
-- Two tables, per-user (individual use, scoped to auth.uid()):
--   lab_reports  — one row per collection event (a blood draw / panel run):
--                  date, source (Quest/Function/…), physician, fasting flag.
--                  Deduped on import_ref (the lab's accession number).
--   lab_results  — one row per marker in a report: value, unit, the reference
--                  range broken into low/high/operator so the app can draw a
--                  "where you fall in range" gauge, plus Quest's H/L flag.
--
-- Trends over time = every lab_results row for a given marker name across all
-- of a user's reports, ordered by the report's collected_on.
-- ============================================================================

create table if not exists public.lab_reports (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  collected_on date not null,
  source       text,                               -- 'Quest', 'Function', 'LabCorp', 'Manual'…
  physician    text,
  fasting      boolean,
  notes        text,
  import_ref   text,                               -- e.g. 'quest:TZ780024D' — dedup key
  created_at   timestamptz not null default now(),
  unique (user_id, import_ref)
);

create table if not exists public.lab_results (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  report_id     uuid not null references public.lab_reports(id) on delete cascade,
  category      text,                              -- UI grouping: 'Lipids','CBC','Thyroid'…
  panel         text,                              -- the lab's panel header, if any
  name          text not null,                     -- marker name, e.g. 'LDL-CHOLESTEROL'
  value_num     numeric,                           -- numeric value (null for qualitative)
  value_text    text,                              -- 'NEGATIVE', '<4', 'YELLOW' — raw as shown
  unit          text,
  ref_operator  text,                              -- 'range'|'lte'|'gte'|'eq'|'qual'|'none'
  ref_low       numeric,
  ref_high      numeric,
  normal_text   text,                              -- expected qualitative result, e.g. 'NEGATIVE'
  flag          text,                              -- 'H' | 'L' | null (from the lab)
  sort_order    integer not null default 0,        -- preserves the report's ordering
  created_at    timestamptz not null default now(),
  unique (report_id, name, panel)
);

create index if not exists lab_reports_user_date_idx on public.lab_reports (user_id, collected_on desc);
create index if not exists lab_results_report_idx    on public.lab_results (report_id);
create index if not exists lab_results_user_name_idx on public.lab_results (user_id, name);

alter table public.lab_reports enable row level security;
alter table public.lab_results enable row level security;

drop policy if exists "own lab_reports" on public.lab_reports;
create policy "own lab_reports" on public.lab_reports
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own lab_results" on public.lab_results;
create policy "own lab_results" on public.lab_results
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================================
-- DONE. Verify:
--   select tablename from pg_tables where tablename like 'lab_%';
-- ============================================================================
