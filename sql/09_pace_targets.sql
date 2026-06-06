-- ============================================================================
-- Coach-set target paces (the "pace sheet"), shown to runners when they log a
-- matching run type / segment. Run in: Supabase Dashboard → SQL Editor.
--
-- Three categories: easy (easy + long runs), tempo, race. Stored as seconds
-- per mile. Coaches edit them on the dashboard; every signed-in user can read.
-- ============================================================================

create table if not exists pace_targets (
  category       text primary key check (category in ('easy','tempo','race')),
  target_seconds integer check (target_seconds between 120 and 1800),  -- 2:00–30:00 /mi
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id)
);

alter table pace_targets enable row level security;

-- Everyone signed in can read the guidance.
drop policy if exists "anyone reads pace targets" on pace_targets;
create policy "anyone reads pace targets" on pace_targets
  for select using (auth.uid() is not null);

-- Only coaches can set them.
drop policy if exists "coach writes pace targets" on pace_targets;
create policy "coach writes pace targets" on pace_targets
  for all using (public.is_coach()) with check (public.is_coach());

-- Seed the three rows (no target yet — coach fills them in).
insert into pace_targets (category) values ('easy'), ('tempo'), ('race')
  on conflict (category) do nothing;

-- ============================================================================
-- DONE. Verify:  select * from pace_targets order by category;
-- ============================================================================
