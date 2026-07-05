-- ============================================================================
-- Two-level activity model: activity_type (Strava-aligned) + sub_type.
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
--   activity_type — run, ride, swim, walk, hike, strength, workout, other
--   sub_type      — for runs: easy, long, tempo, intervals, race, recovery,
--                   workout (null for non-run activities)
--
-- The old single `run_type` column (easy/…/cross_train) is migrated into the
-- two new columns and then relaxed (nullable, constraints dropped) so it stops
-- blocking inserts. It's left in place as vestigial; the app no longer uses it.
-- ============================================================================

alter table public.runs
  add column if not exists activity_type text,
  add column if not exists sub_type      text;

-- Backfill from the legacy run_type / cross_train_activity.
update public.runs set
  activity_type = case when run_type = 'cross_train'
                       then lower(coalesce(nullif(cross_train_activity,''),'workout'))
                       else 'run' end,
  sub_type      = case when run_type = 'cross_train' then null else run_type end
where activity_type is null;

-- Normalize common cross-train labels into our vocabulary (best effort).
update public.runs set activity_type='ride'     where activity_type ~* '(bik|cycl|ride)';
update public.runs set activity_type='swim'     where activity_type ~* 'swim';
update public.runs set activity_type='walk'     where activity_type ~* 'walk';
update public.runs set activity_type='hike'     where activity_type ~* 'hik';
update public.runs set activity_type='strength' where activity_type ~* '(weight|strength|lift)';
update public.runs set activity_type='workout'  where activity_type ~* '(ellipt|yoga|pilat|hiit|stair|crossfit)';
update public.runs set activity_type='other'
  where activity_type not in ('run','ride','swim','walk','hike','strength','workout');

alter table public.runs alter column activity_type set default 'run';
update public.runs set activity_type='run' where activity_type is null;
alter table public.runs alter column activity_type set not null;

-- Relax the legacy run_type so inserts no longer require/limit it. Drop every
-- check constraint that references run_type or cross_train_activity (names are
-- auto-generated, so find them dynamically), then drop NOT NULL.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.runs'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ~ '(run_type|cross_train_activity)'
  loop
    execute format('alter table public.runs drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.runs alter column run_type drop not null;

create index if not exists runs_activity_type_idx on public.runs (activity_type);

-- ============================================================================
-- DONE. Verify:
--   select activity_type, sub_type, count(*) from public.runs
--     group by 1,2 order by 1,2;
-- ============================================================================
