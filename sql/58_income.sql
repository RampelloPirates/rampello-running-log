-- ============================================================================
-- Income — the other half of the month
--
-- Run in the Supabase SQL Editor, after 57_money.sql. Safe to run more than once.
--
-- 57 modelled the money going out. The spreadsheet this replaces does more than
-- that: its top block is Payroll / Abigail / Reimbursement / Other, and the row
-- the whole sheet exists to produce is Surplus/Deficit at the bottom. Without
-- income that number cannot be computed, so importing the file without these
-- two tables would throw away half of it.
--
--   income_sources  — the recurring template. Mirrors `bills`.
--   income_entries  — one row per source per month. Mirrors `bill_payments`.
--
-- WHY NOT JUST A NEGATIVE BILL
-- ----------------------------
-- It would work arithmetically and it would be wrong in every other way. A bill
-- has a due date, an autopay flag, a paid/unpaid state and an account it pays
-- down; none of those mean anything for a paycheque. Overloading the table
-- would mean every query that touches bills has to remember to exclude the rows
-- that are secretly income — and the one that forgets shows your salary in the
-- overdue list. Two small tables cost less than that.
--
-- WHY income_entries HAS NO paid_on
-- ---------------------------------
-- The asymmetry is real, not an oversight. You choose when a bill is paid, so
-- that state is worth tracking. Income either arrived or it didn't, and by the
-- time you are recording the figure it has arrived. One amount per month is the
-- whole fact.
-- ============================================================================


create table if not exists public.income_sources (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,

  -- Same meaning as bills.amount_default: null is "varies", which for income is
  -- the common case (reimbursements, side work) rather than the exception.
  amount_default  numeric(12,2) check (amount_default is null or amount_default >= 0),

  active          boolean not null default true,
  sort_order      integer not null default 0,
  notes           text,
  created_at      timestamptz not null default now()
);


create table if not exists public.income_entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  source_id   uuid not null references public.income_sources(id) on delete cascade,
  period      date not null,
  amount      numeric(12,2) not null check (amount >= 0),
  notes       text,
  created_at  timestamptz not null default now(),

  constraint income_entries_first_of_month check (period = date_trunc('month', period)::date),
  unique (source_id, period)
);


create index if not exists income_entries_user_period_idx on public.income_entries (user_id, period desc);
create index if not exists income_sources_user_idx        on public.income_sources (user_id) where active;


alter table public.income_sources enable row level security;
alter table public.income_entries enable row level security;

drop policy if exists "own income_sources" on public.income_sources;
create policy "own income_sources" on public.income_sources
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own income_entries" on public.income_entries;
create policy "own income_entries" on public.income_entries
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ============================================================================
-- DONE. Verify:
--
--   select tablename from pg_tables
--    where tablename in ('income_sources','income_entries');
--
-- Once there is data, this is the Surplus/Deficit the Money page shows — the
-- same row the spreadsheet computes at the bottom of its expense block:
--
--   with inc as (
--     select period, sum(amount) as money_in
--       from public.income_entries group by period),
--   out as (
--     select period, sum(coalesce(amount_paid, amount_due)) as money_out
--       from public.bill_payments group by period)
--   select coalesce(inc.period, out.period) as month,
--          coalesce(money_in,0)  as money_in,
--          coalesce(money_out,0) as money_out,
--          coalesce(money_in,0) - coalesce(money_out,0) as surplus
--     from inc full outer join out on inc.period = out.period
--    order by 1;
--
-- coalesce(amount_paid, amount_due) is deliberate: a month you have finished
-- paying is measured by what actually left, and a month in progress falls back
-- to what is still expected, so the current month reads as a forecast rather
-- than as a surplus you have not earned yet.
-- ============================================================================
