-- ============================================================================
-- Open-access mode: drop auth-keyed RLS so the anon key can read/write
-- everything. This is intentional — the app is being run as an open demo
-- where any visitor picks an identity from a roster dropdown.
--
-- Run once in the Supabase SQL Editor.
--
-- WARNING: After this runs, anyone with the public Supabase URL + anon key
-- (which is embedded in every HTML file) can read, edit, or delete any row
-- in these tables. Do not run this against a project that holds real
-- private data you want to keep private.
-- ============================================================================

-- Drop all existing policies (they reference auth.uid() which is null for anon).
drop policy if exists "athlete sees self"           on athletes;
drop policy if exists "athlete updates self"        on athletes;
drop policy if exists "coach reads all athletes"    on athletes;
drop policy if exists "coach inserts athletes"      on athletes;
drop policy if exists "coach updates athletes"      on athletes;
drop policy if exists "coach deletes athletes"      on athletes;
drop policy if exists "anon can self signup"        on athletes;

drop policy if exists "coach reads coaches"         on coaches;
drop policy if exists "coach inserts coaches"       on coaches;
drop policy if exists "coach updates coaches"       on coaches;
drop policy if exists "coach deletes coaches"       on coaches;

drop policy if exists "athlete owns runs"           on runs;
drop policy if exists "coach manages runs"          on runs;

drop policy if exists "athlete owns segments"      on run_segments;
drop policy if exists "coach manages segments"     on run_segments;

drop policy if exists "athlete owns race results"   on race_results;
drop policy if exists "coach manages race results"  on race_results;

-- Turn RLS off everywhere so the anon role has free access.
alter table athletes     disable row level security;
alter table coaches      disable row level security;
alter table runs         disable row level security;
alter table run_segments disable row level security;
alter table race_results disable row level security;
