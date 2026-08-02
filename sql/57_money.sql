-- ============================================================================
-- Money — the monthly bill run, and net worth
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- This replaces a spreadsheet with a column per month. That shape is why the
-- file never ends: it grows sideways forever and nothing can query across it.
-- Four tables here, all per-user (individual use, scoped to auth.uid() the
-- same way supplements and vitals are):
--
--   bills             — the recurring template. Mortgage, car, power, Amex.
--   bill_payments     — one row per bill per month. The spreadsheet, unpivoted.
--   accounts          — what you own and what you owe. The net worth tab's rows.
--   account_balances  — one row per account per month.
--
-- NOTHING IN HERE IS A CREDENTIAL
-- ------------------------------
-- No account numbers, no logins, no routing or card numbers, and no column to
-- put them in. A bill is a name, a day of the month and an amount; an account
-- is a name and a balance. That is a deliberate ceiling on what a leak of this
-- database would be worth — someone learns what you owe, not how to move money.
-- If you ever feel the urge to add a `login` or `acct_number` column, that is
-- the moment to put it in a real password manager instead.
--
-- THE LINK BETWEEN THE TWO HALVES
-- -------------------------------
-- bills.account_id is the whole reason this beats two spreadsheet tabs. Your
-- mortgage payment and your mortgage balance are the same fact seen twice: one
-- is the money leaving each month, the other is what is left. Point the bill at
-- the liability and the app can show the payment history next to the balance it
-- is paying down. Same for the car loan and each credit card.
--
-- It is nullable on purpose. Power and internet are bills that pay down
-- nothing, and a 401k is a balance nobody bills you for. Neither is a broken
-- row, so neither side is required to have a partner.
-- ============================================================================


-- ── accounts: what you own, what you owe ───────────────────────────────────
-- Created first because bills references it.
--
-- kind is the sign in the net worth sum; category is what it is. Splitting them
-- means the arithmetic never has to parse a label — assets add, liabilities
-- subtract, and that holds however many categories get added later.
create table if not exists public.accounts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  kind        text not null check (kind in ('asset','liability')),
  category    text not null,
  active      boolean not null default true,     -- soft delete: keeps history readable
  sort_order  integer not null default 0,
  notes       text,
  created_at  timestamptz not null default now(),

  -- Category has to agree with kind. A retirement account that claims to be a
  -- liability is a typo, and it would quietly subtract six figures from your
  -- net worth rather than fail — exactly the kind of wrong number you would
  -- believe. Cheap to check here, so it is checked here.
  constraint accounts_category_matches_kind check (
    (kind = 'asset'     and category in ('cash','investment','retirement','property','vehicle','other'))
    or
    (kind = 'liability' and category in ('credit_card','loan','mortgage','other'))
  )
);


-- ── account_balances: one number per account per month ─────────────────────
-- Balances are stored as positive magnitudes for BOTH kinds. A $240,000
-- mortgage is 240000, not -240000, and net worth is sum(assets) −
-- sum(liabilities). Storing liabilities negative would work too, but then every
-- entry form has to explain a minus sign and one forgotten sign flips the total
-- by twice the balance. The sign lives in `kind`, where it cannot be typed
-- wrong.
create table if not exists public.account_balances (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  account_id  uuid not null references public.accounts(id) on delete cascade,
  as_of       date not null,
  balance     numeric(12,2) not null,
  created_at  timestamptz not null default now(),

  -- One reading per account per month, always dated the 1st. Net worth is a
  -- monthly series, so a stray 2026-08-14 row would silently start a second
  -- series that no month view would ever line up with.
  constraint account_balances_first_of_month check (as_of = date_trunc('month', as_of)::date),
  unique (account_id, as_of)
);


-- ── bills: the recurring template ──────────────────────────────────────────
create table if not exists public.bills (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  category        text not null default 'other'
    check (category in ('housing','auto','utilities','insurance','credit','subscription','health','other')),

  -- Day of the month it is due. 29–31 are allowed and clamped to the last day
  -- of short months when a payment row is generated — see the note in
  -- money.html. Storing the clamp instead would lose the fact that it is
  -- genuinely a 31st bill.
  due_day         integer check (due_day between 1 and 31),

  -- Null means "varies" — power, water, a credit card. That is a real and
  -- common state, not a missing value, and the month view renders it as a
  -- blank waiting for the actual figure rather than guessing.
  amount_default  numeric(12,2) check (amount_default is null or amount_default >= 0),

  autopay         boolean not null default false,
  account_id      uuid references public.accounts(id) on delete set null,
  active          boolean not null default true,
  sort_order      integer not null default 0,
  notes           text,
  created_at      timestamptz not null default now()
);


-- ── bill_payments: the spreadsheet, unpivoted ──────────────────────────────
-- One row per bill per month. This is the table the old file's month columns
-- become: a cell at (Power, August) is a row here.
create table if not exists public.bill_payments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  bill_id     uuid not null references public.bills(id) on delete cascade,

  -- The month this payment belongs to, always the 1st. Kept separate from
  -- due_on because they answer different questions: period is which column of
  -- the old spreadsheet this is, due_on is the actual calendar date, and for a
  -- bill due on the 1st those differ the moment you look at a Sunday.
  period      date not null,
  due_on      date,

  amount_due  numeric(12,2) check (amount_due  is null or amount_due  >= 0),
  amount_paid numeric(12,2) check (amount_paid is null or amount_paid >= 0),

  -- Paid-ness is derived from this being non-null. There is deliberately no
  -- `paid` boolean: two columns that encode the same fact will eventually
  -- disagree, and then neither can be trusted.
  paid_on     date,

  notes       text,
  created_at  timestamptz not null default now(),

  constraint bill_payments_first_of_month check (period = date_trunc('month', period)::date),
  unique (bill_id, period)
);


-- ── indexes ────────────────────────────────────────────────────────────────
-- The month view is the hot path: every load asks for one user's payments in
-- one period, so that is the index. The rest are small lists read whole.
create index if not exists bill_payments_user_period_idx on public.bill_payments (user_id, period desc);
create index if not exists bill_payments_bill_idx        on public.bill_payments (bill_id, period desc);
create index if not exists bills_user_idx                on public.bills (user_id) where active;
create index if not exists accounts_user_idx             on public.accounts (user_id) where active;
create index if not exists account_balances_user_asof_idx on public.account_balances (user_id, as_of desc);


-- ── RLS ────────────────────────────────────────────────────────────────────
-- Same shape as every other personal table: you see your rows and nobody
-- else's. Note this is authorization, not encryption — see the header. It is
-- the right control for amounts; it would not be enough for secrets.
alter table public.accounts         enable row level security;
alter table public.account_balances enable row level security;
alter table public.bills            enable row level security;
alter table public.bill_payments    enable row level security;

drop policy if exists "own accounts" on public.accounts;
create policy "own accounts" on public.accounts
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own account_balances" on public.account_balances;
create policy "own account_balances" on public.account_balances
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own bills" on public.bills;
create policy "own bills" on public.bills
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own bill_payments" on public.bill_payments;
create policy "own bill_payments" on public.bill_payments
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ============================================================================
-- DONE. Verify the four tables landed:
--
--   select tablename from pg_tables
--    where tablename in ('bills','bill_payments','accounts','account_balances');
--
-- And that all four are locked down — every row should read `true`:
--
--   select relname, relrowsecurity from pg_class
--    where relname in ('bills','bill_payments','accounts','account_balances');
--
-- Nothing is seeded. Add your bills and accounts in the Money page, or let the
-- Excel importer do it — the importer writes through these same tables and has
-- no privileges the page does not.
--
-- Once there is data, this is the net worth series the page draws:
--
--   select b.as_of,
--          sum(case when a.kind = 'asset'     then b.balance else 0 end) as assets,
--          sum(case when a.kind = 'liability' then b.balance else 0 end) as debts,
--          sum(case when a.kind = 'asset'     then b.balance else -b.balance end) as net_worth
--     from public.account_balances b
--     join public.accounts a on a.id = b.account_id
--    group by b.as_of
--    order by b.as_of;
-- ============================================================================
