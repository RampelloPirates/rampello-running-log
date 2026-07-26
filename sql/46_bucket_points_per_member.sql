-- ============================================================================
-- A tier is worth a different number to each kid
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- One value per tier can't make two kids land on their targets. They have
-- different chores at different frequencies, so the arithmetic that gets Emma
-- to 500 is not the arithmetic that gets her brother there — the small tier
-- might need to be 3 for one and 2 for the other. Sharing one number means
-- one of them is always short or always over.
--
-- Why per-member VALUES rather than per-member TIERS
-- --------------------------------------------------
-- The obvious move is to give each kid their own set of tiers. It breaks
-- immediately: a chore the two of them do together belongs to one tier row,
-- and one tier row can only belong to one kid. Keeping the tier shared and
-- varying only its value sidesteps that — "Quick" means the same category of
-- work for everyone, and each kid has their own price for it.
--
-- point_buckets.points stays as the default, used by anyone with no row here.
-- That keeps every existing chore priced exactly as it was until someone
-- deliberately sets a per-kid number.
-- ============================================================================

-- Composite-FK targets, so a row can't name a tier from one household and a
-- member from another. Same reasoning as chore_completions in 34.
create unique index if not exists point_buckets_id_household_uniq
  on public.point_buckets (id, household_id);
create unique index if not exists household_members_id_household_uniq
  on public.household_members (id, household_id);

create table if not exists public.bucket_points (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  bucket_id     uuid not null,
  member_id     uuid not null,
  points        integer not null default 0,
  created_at    timestamptz not null default now(),

  foreign key (bucket_id, household_id)
    references public.point_buckets (id, household_id) on delete cascade,
  foreign key (member_id, household_id)
    references public.household_members (id, household_id) on delete cascade
);

alter table public.bucket_points
  drop constraint if exists bucket_points_points_check;
alter table public.bucket_points
  add constraint bucket_points_points_check check (points >= 0);

-- One value per tier per kid.
create unique index if not exists bucket_points_uniq
  on public.bucket_points (bucket_id, member_id);

create index if not exists bucket_points_household_idx
  on public.bucket_points (household_id, member_id);

alter table public.bucket_points enable row level security;

drop policy if exists "household bucket points" on public.bucket_points;
create policy "household bucket points" on public.bucket_points
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

-- ============================================================================
-- DONE. Nothing is seeded — every tier keeps its single value until you set a
-- per-kid one, so no chore changes worth today.
--
-- What each kid is on, once you have:
--
--   select m.display_name, b.name, coalesce(bp.points, b.points) as worth,
--          (bp.id is not null) as is_override
--     from public.household_members m
--     cross join public.point_buckets b
--     left join public.bucket_points bp
--            on bp.bucket_id = b.id and bp.member_id = m.id
--    where m.active and m.role = 'kid' and b.household_id = m.household_id
--    order by m.display_name, b.sort_order;
-- ============================================================================
