-- ============================================================================
-- Oura VO2 max → oura_daily
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- Safe to run more than once.
-- ============================================================================
--
-- Oura estimates VO2 max from an in-app walking test you take by hand, exposed
-- on the v2 API at /usercollection/vO2_max. It is sparse — only the days you
-- actually took the test — which is exactly why it's worth having: it is the
-- only MEASURED point in the aerobic-fitness picture. Everything else the app
-- shows (VDOT from race efforts, the HRmax/HRrest ratio) is a formula with an
-- unknown absolute offset. These readings are what anchor those curves.
--
-- Nullable and unconstrained on purpose: most days won't have one.
-- ============================================================================

alter table public.oura_daily
  add column if not exists vo2_max numeric(5,2);

comment on column public.oura_daily.vo2_max is
  'ml/kg/min from Oura''s in-app walking test. Present only on days the test was taken.';

-- ============================================================================
-- DONE. The next oura_sync run backfills it over SYNC_DAYS (default 14). For a
-- one-time deeper backfill, run the workflow manually with a larger day count.
--
-- Verify:  select day, vo2_max from public.oura_daily
--          where vo2_max is not null order by day desc;
-- ============================================================================
