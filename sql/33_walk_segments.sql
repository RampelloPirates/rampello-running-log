-- ============================================================================
-- A 'walk' segment type
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- Safe to run more than once.
-- ============================================================================
--
-- Walk breaks had nowhere to go. The segment types covered every kind of
-- running — warmup, tempo, interval, rest, cooldown — but a walk is not a kind
-- of running, and the closest available label was 'rest', which in an interval
-- session means a jog recovery. Marking a walk as 'rest' therefore made it
-- indistinguishable from running, and it kept counting toward pace.
--
-- With 'walk' available, the app can exclude those stretches from pace and
-- mileage while leaving everything else alone. 'rest' deliberately still
-- counts: jogging between reps is running.
-- ============================================================================

alter table public.run_segments
  drop constraint if exists run_segments_segment_type_check;

alter table public.run_segments
  add constraint run_segments_segment_type_check check (segment_type in (
    'warmup','easy','tempo','threshold','interval','rest',
    'hill','fartlek','strides','cooldown','walk'
  ));

-- ============================================================================
-- DONE. Verify — this should succeed and then clean up after itself:
--
--   select segment_type, count(*) from public.run_segments
--   group by segment_type order by count(*) desc;
--
-- Anything you previously marked 'rest' that was really a walk can be moved:
--   update public.run_segments set segment_type = 'walk' where id = '<id>';
-- ============================================================================
