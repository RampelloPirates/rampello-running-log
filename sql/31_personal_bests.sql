-- ============================================================================
-- Personal bests
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- Safe to run more than once.
-- ============================================================================
--
-- Two sources feed the bests board, and they answer different questions:
--
--   · DERIVED — the app scans each run's sample stream for the fastest rolling
--     0.5 mi / 1K / mile / 5K / 10K / half anywhere inside it, plus the longest
--     single run. Nothing is stored: it recomputes, so it can never drift out
--     of step with the runs it came from.
--   · CARRIED — this table. Bests from before the app existed (Garmin has years
--     of them) and anything set on a run with no stream to scan. These are the
--     floor the derived numbers have to beat.
--
-- The board shows whichever is better and says which it was.
--
-- `achieved_on` is nullable on purpose: Garmin's all-time list gives a time but
-- not a date. A best with no date still counts all-time, it just can't appear
-- in a by-year breakdown — which is the honest handling, rather than guessing
-- a year and polluting the yearly table.
-- ============================================================================

create table if not exists public.personal_bests (
  id             uuid primary key default gen_random_uuid(),
  athlete_id     uuid not null references public.athletes(id) on delete cascade,
  distance_key   text not null,          -- '0.5mi' | '1k' | '1mi' | '5k' | '10k' | 'half' | 'farthest'
  seconds        integer,                -- the time; null for 'farthest'
  distance_miles numeric(6,2),           -- only for 'farthest'
  achieved_on    date,                   -- null when the source doesn't say
  source         text not null default 'Manual',   -- 'Garmin', 'Manual', …
  notes          text,
  created_at     timestamptz not null default now(),
  -- One carried best per distance per source, so re-running this file updates
  -- rather than duplicating.
  unique (athlete_id, distance_key, source)
);

create index if not exists personal_bests_athlete_idx
  on public.personal_bests (athlete_id, distance_key);

alter table public.personal_bests enable row level security;

drop policy if exists "athlete owns bests" on public.personal_bests;
create policy "athlete owns bests" on public.personal_bests
  for all
  using     (athlete_id in (select id from athletes where auth_user_id = auth.uid()))
  with check(athlete_id in (select id from athletes where auth_user_id = auth.uid()));

-- ---------------------------------------------------------------------------
-- Seed the Garmin all-time list. Scoped to the signed-in athlete, so run this
-- while logged into the dashboard as yourself.
--
-- If auth.uid() comes back null here (the SQL Editor sometimes connects as an
-- admin role with no JWT), swap `auth.uid()` for your athletes.id and re-run.
-- ---------------------------------------------------------------------------
insert into public.personal_bests (athlete_id, distance_key, seconds, distance_miles, source, notes)
select a.id, v.distance_key, v.seconds, v.distance_miles, 'Garmin', 'From Garmin all-time bests'
from   public.athletes a
cross  join (values
    ('1k',       243,  null::numeric),   -- 4:03
    ('1mi',      425,  null),            -- 7:05
    ('5k',      1528,  null),            -- 25:28
    ('10k',     3261,  null),            -- 54:21
    ('half',    7360,  null),            -- 2:02:40
    ('farthest', null, 13.29)
  ) as v(distance_key, seconds, distance_miles)
where  a.auth_user_id = auth.uid()
on conflict (athlete_id, distance_key, source) do update
  set seconds        = excluded.seconds,
      distance_miles = excluded.distance_miles,
      notes          = excluded.notes;

-- Note: 0.5 mi is deliberately absent. Garmin doesn't track it, so there is no
-- carried value — it starts empty and fills in from your streams.

-- ============================================================================
-- DONE. Verify:
--   select distance_key, seconds, distance_miles, source
--   from public.personal_bests order by distance_key;
-- Six rows expected. Zero rows means auth.uid() was null — see the note above.
-- ============================================================================
