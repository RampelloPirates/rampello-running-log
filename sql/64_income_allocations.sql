-- ============================================================================
-- Where the money lands when it comes in
--
-- Run in the Supabase SQL Editor, after 63. Safe to run more than once.
--
-- 63 gave bills a from and a to. Income needs the same, with one complication
-- bills do not have: a paycheque does not arrive in one place. Direct deposit
-- splits it — some to Car Savings, some to Vacation Checking, the rest to the
-- current account — and all of it is one paycheque.
--
-- WHY NOT JUST A to_account_id ON THE SOURCE
-- ------------------------------------------
-- Because expressing a split with a single destination means breaking Payroll
-- into "Payroll — main", "Payroll — car" and "Payroll — vacation" and dividing
-- the figure between them every month. That trades one number you know for
-- three you have to keep reconciling, and it quietly changes what Payroll means
-- — the row that used to be your pay becomes a fragment of it. Money in and
-- Surplus/Deficit would still come out right, but only as long as the three are
-- maintained together.
--
-- So the source keeps its single figure and carries carve-outs beneath it.
--
--   income_sources.to_account_id   where the remainder lands
--   income_allocations             the named slices taken off the top
--
-- The remainder is deliberately NOT stored. It is the month's amount minus the
-- allocations, computed at read time, so it cannot disagree with the figure it
-- is derived from. A stored remainder is a third number that has to be kept in
-- step with two others, and it is the one that will be wrong.
--
-- STANDING, NOT MONTHLY
-- ---------------------
-- An allocation is an arrangement with the bank, not an event: $400 to Car
-- Savings every payday until you change it. So it hangs off the source, like
-- bills.amount_default, rather than off each month's entry. If a month is
-- genuinely different, edit that month's amount — the remainder absorbs it.
--
-- Nothing here moves a balance either, for the same reason as 63: the balance
-- you type each month came off a statement that already includes the deposit.
-- ============================================================================


alter table public.income_sources
  add column if not exists to_account_id uuid references public.accounts(id) on delete set null;


create table if not exists public.income_allocations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  source_id   uuid not null references public.income_sources(id) on delete cascade,

  -- cascade rather than set null: an allocation naming no account is not a
  -- fact about anything, unlike a bill, which is still a bill without a link.
  account_id  uuid not null references public.accounts(id) on delete cascade,

  amount      numeric(12,2) not null check (amount >= 0),
  created_at  timestamptz not null default now(),

  -- One slice per account per source. Two rows both sending Payroll to Car
  -- Savings is not a richer arrangement, it is the same one entered twice, and
  -- it would silently double what the account appears to receive.
  unique (source_id, account_id)
);

create index if not exists income_allocations_source_idx on public.income_allocations (source_id);
create index if not exists income_allocations_acct_idx   on public.income_allocations (account_id);

alter table public.income_allocations enable row level security;

drop policy if exists "own income_allocations" on public.income_allocations;
create policy "own income_allocations" on public.income_allocations
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ============================================================================
-- DONE. Nothing is seeded — the deposit amounts are yours to enter, on each
-- income source in the app, under Splits.
--
-- Once they are in, this is what the Money page shows beneath each source:
--
--   select s.name as source, a.name as lands_in, al.amount
--     from public.income_allocations al
--     join public.income_sources s on s.id = al.source_id
--     join public.accounts a       on a.id = al.account_id
--    order by s.sort_order, a.name;
--
-- And the check worth running after entering them — no source should be
-- allocating more than it actually brings in:
--
--   select s.name,
--          max(e.amount)     as received_latest,
--          sum(al.amount)    as allocated,
--          max(e.amount) - coalesce(sum(al.amount), 0) as remainder
--     from public.income_sources s
--     left join public.income_allocations al on al.source_id = s.id
--     left join public.income_entries e on e.source_id = s.id
--          and e.period = (select max(period) from public.income_entries)
--    group by s.name
--   having max(e.amount) - coalesce(sum(al.amount), 0) < 0;
--
-- Zero rows is what you want. Any row means that source's splits exceed what it
-- brought in that month; the app says so in place rather than refusing to save,
-- since a genuinely light month is a real thing and not a data error.
-- ============================================================================
