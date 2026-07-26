-- ============================================================================
-- Point buckets — price the tiers, not every chore
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Points per chore was fine for three chores and unworkable for twenty. The
-- weekly total has to land on the target, and the total is not the sum of the
-- point values — it's the sum of value TIMES how often each one comes round.
-- Making the bed daily at 5 is 35 a week; taking the bins out on a Tuesday at
-- 20 is 20. Add one chore and every number is wrong again.
--
-- So chores join a bucket, and the bucket carries the number. Re-price a tier
-- and everything on it moves together. Adding a chore is then a question of
-- which tier it belongs to rather than what it's worth, which is both an
-- easier question and the one you can actually answer consistently.
--
-- chores.points survives as the fallback for anything with no bucket, so
-- nothing that already exists has to be migrated to keep working. The app
-- reads the bucket when there is one and the column when there isn't.
--
-- Buckets are per household because two families won't agree on what a tier
-- is worth, and because the seed below has to belong to someone.
-- ============================================================================

create table if not exists public.point_buckets (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  name          text not null,
  points        integer not null default 0,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now()
);

alter table public.point_buckets
  drop constraint if exists point_buckets_points_check;
alter table public.point_buckets
  add constraint point_buckets_points_check check (points >= 0);

create index if not exists point_buckets_household_idx
  on public.point_buckets (household_id, sort_order);

-- on delete set null, deliberately: losing a tier must not delete the chores
-- that were on it. They fall back to chores.points, which the app shows as
-- unbucketed so it's visible rather than silently zero.
alter table public.chores
  add column if not exists bucket_id uuid references public.point_buckets(id) on delete set null;

create index if not exists chores_bucket_idx on public.chores (bucket_id);

-- ── A starting set, so the tool opens with something to move ───────────────
-- Only for households that have none, so a second run can't re-seed over
-- tiers you've since renamed or re-priced.
insert into public.point_buckets (household_id, name, points, sort_order)
select h.id, v.name, v.pts, v.ord
  from public.households h
 cross join (values ('Quick', 5, 0), ('Standard', 10, 1), ('Big', 25, 2))
         as v(name, pts, ord)
 where not exists (
   select 1 from public.point_buckets b where b.household_id = h.id
 );

-- ── RLS ────────────────────────────────────────────────────────────────────
alter table public.point_buckets enable row level security;

drop policy if exists "household point buckets" on public.point_buckets;
create policy "household point buckets" on public.point_buckets
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

-- ============================================================================
-- DONE. Verify the seed landed once per household:
--
--   select h.name, b.name, b.points
--   from public.point_buckets b join public.households h on h.id = b.household_id
--   order by h.name, b.sort_order;
--
-- Chores are still on their own points until you assign them a tier:
--
--   select title, points, bucket_id from public.chores order by title;
-- ============================================================================
