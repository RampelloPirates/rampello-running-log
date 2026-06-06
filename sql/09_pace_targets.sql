-- ============================================================================
-- Per-athlete target paces (the coach's pace sheet, individualized per runner),
-- shown to that runner when they log a matching run type / segment.
-- Run in: Supabase Dashboard → SQL Editor.
--
-- Three categories per athlete: easy (easy + long runs), tempo, race. Stored as
-- seconds per mile. Coaches set them on an athlete's detail page; the athlete
-- sees their own when logging.
--
-- NOTE: drops any earlier team-wide pace_targets table and recreates it
-- per-athlete. Safe if you only just created the old one (it had no real data).
-- ============================================================================

drop table if exists pace_targets cascade;

create table pace_targets (
  athlete_id     uuid not null references athletes(id) on delete cascade,
  category       text not null check (category in ('easy','tempo','race')),
  target_seconds integer check (target_seconds between 120 and 1800),  -- 2:00–30:00 /mi
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id),
  primary key (athlete_id, category)
);

alter table pace_targets enable row level security;

-- A runner sees their own targets.
drop policy if exists "athlete reads own pace targets" on pace_targets;
create policy "athlete reads own pace targets" on pace_targets
  for select using (
    athlete_id in (select id from athletes where auth_user_id = auth.uid())
  );

-- Coaches read and set targets for everyone.
drop policy if exists "coach manages pace targets" on pace_targets;
create policy "coach manages pace targets" on pace_targets
  for all using (public.is_coach()) with check (public.is_coach());

-- ============================================================================
-- DONE. Verify:  select * from pace_targets order by athlete_id, category;
-- ============================================================================
