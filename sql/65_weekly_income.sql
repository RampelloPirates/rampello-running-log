-- ============================================================================
-- Weekly pay, split five ways
--
-- Run in the Supabase SQL Editor, after 64. Safe to run more than once.
--
-- 64 modelled income as one figure a month with standing slices taken off it.
-- That fits a salary paid monthly into one place. It does not fit being paid
-- weekly for an amount that moves, split across five accounts every time —
-- there is no standing figure to take a slice of, and the slice itself is
-- different each week.
--
-- So the detail becomes the record: one row per account per payday.
--
--   income_deposits   $620 into Vacation Checking on 7 Aug
--
-- A month's income from a source is then the sum of its deposits in that month,
-- and the split across accounts falls out of the same rows. Neither is stored
-- twice.
--
-- WHAT HAPPENS TO income_entries AND income_allocations
-- -----------------------------------------------------
-- Both stay, and the rule between them is precedence rather than replacement:
--
--   a source with deposits in a month -> that month is the sum of its deposits,
--                                        and its allocations are ignored
--   a source with none                -> the monthly entry and its allocations,
--                                        exactly as before
--
-- This is not a transition to be finished later. The imported history is 32
-- months of monthly totals with no account detail at all, because the
-- spreadsheet never had any, and inventing weekly rows for it would be
-- fabricating records. Those months keep working through income_entries. The
-- other sources — Abigail, Reimbursement — really are occasional monthly
-- amounts and there is nothing to gain by making them weekly.
--
-- WHY NOT STORE THE MONTH'S TOTAL AS WELL
-- ---------------------------------------
-- Because then a month has two figures that must agree, and the day they do not
-- there is nothing to say which is right. The sum is cheap and cannot drift.
-- Same reason 64 computes the remainder instead of storing it.
-- ============================================================================


alter table public.income_sources
  add column if not exists cadence text not null default 'monthly'
    check (cadence in ('monthly', 'weekly'));


create table if not exists public.income_deposits (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  source_id   uuid not null references public.income_sources(id) on delete cascade,

  -- cascade, like income_allocations: a deposit that names no account is not a
  -- fact about anything.
  account_id  uuid not null references public.accounts(id) on delete cascade,

  -- The actual payday, not the month. Which month it counts in is derived from
  -- it, so a paycheque on 31 July and one on 1 August land where they belong
  -- without anyone deciding.
  paid_on     date not null,

  amount      numeric(12,2) not null check (amount >= 0),
  created_at  timestamptz not null default now(),

  -- One row per account per payday. A second row for the same three is the same
  -- deposit entered twice, and would quietly double what that account received.
  unique (source_id, paid_on, account_id)
);

create index if not exists income_deposits_user_date_idx on public.income_deposits (user_id, paid_on desc);
create index if not exists income_deposits_source_idx    on public.income_deposits (source_id, paid_on desc);
create index if not exists income_deposits_acct_idx      on public.income_deposits (account_id);

alter table public.income_deposits enable row level security;

drop policy if exists "own income_deposits" on public.income_deposits;
create policy "own income_deposits" on public.income_deposits
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());


-- -- STEP 2: Payroll is the weekly one ---------------------------------------
-- Only this source. Everything else stays monthly, which is what it is.

with me as (select id from auth.users order by created_at limit 1)
update public.income_sources s
   set cadence = 'weekly'
  from me
 where s.user_id = me.id
   and lower(s.name) = 'payroll'
   and s.cadence <> 'weekly';


-- ============================================================================
-- DONE. Nothing else is seeded — the paycheques are yours to enter, in the app,
-- under Income on the month you are looking at.
--
-- Two of the five accounts you named do not exist yet under those names. What
-- you have is:
--
--   select name, kind, category from public.accounts
--    where active order by name;
--
-- "Vacation Checking/Savings", "Publix 401K" and "HSA Account" are already
-- there and are presumably the ones you mean. "Chase Checking" and "BMW
-- Checking" are not — the nearest are "iThink Checking" and "Car Savings".
-- Either rename those in the app or add the two new ones; the deposit form will
-- offer whatever exists.
--
-- Once a few paycheques are in, this is the month they add up to:
--
--   select date_trunc('month', paid_on)::date as month,
--          count(distinct paid_on)            as paydays,
--          sum(amount)                        as total
--     from public.income_deposits
--    group by 1 order by 1 desc;
--
-- And where it went:
--
--   select a.name, count(*) as deposits, sum(d.amount) as total
--     from public.income_deposits d
--     join public.accounts a on a.id = d.account_id
--    where d.paid_on >= date_trunc('month', current_date)
--    group by a.name order by 3 desc;
-- ============================================================================
