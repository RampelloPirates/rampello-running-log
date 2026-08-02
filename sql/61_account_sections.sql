-- ============================================================================
-- Sections for the Net Worth side, and the equity they make possible
--
-- Run in the Supabase SQL Editor, after 60. Safe to run more than once.
--
-- 60 gave the bills their spreadsheet blocks back. This does the same for the
-- Net Worth sheet, which had three of its own: Cash & Short Term Investments,
-- Retirement, and Real Estate.
--
-- WHY THIS IS NOT JUST COSMETIC
-- ----------------------------
-- Real Estate was House Zestimate minus House Balance — an asset and a
-- liability netted into a single figure. The page could not show that at all,
-- because it grouped by accounts.kind, which put the house in Assets and the
-- mortgage in Debts, in separate cards on opposite sides of the screen.
--
-- kind is the right thing to store: it is what decides whether a balance adds
-- or subtracts, and net worth is sum(assets) - sum(liabilities) however the
-- rows are arranged. But that is an argument about arithmetic, and it had been
-- allowed to dictate the layout. The total is the same either way, so grouping
-- is free to follow how the household actually thinks — and a house with a
-- mortgage against it is one holding worth one number.
--
-- A section is therefore allowed to hold both sides, and subtotals to the net.
-- Cash and Retirement contain assets only, so their net is just their total;
-- Real Estate contains both, so its net is the equity.
--
-- Deliberately a separate table from bill_sections rather than one shared table
-- with a scope column. bill_sections is already live and populated, and the two
-- never mix: no query wants bill sections and account sections together, and a
-- shared table would need a scope filter on every one of them, which is exactly
-- the sort of filter that gets forgotten once.
-- ============================================================================


create table if not exists public.account_sections (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.accounts
  add column if not exists section_id uuid references public.account_sections(id) on delete set null;

create index if not exists account_sections_user_idx on public.account_sections (user_id, sort_order);
create index if not exists accounts_section_idx      on public.accounts (section_id);

alter table public.account_sections enable row level security;

drop policy if exists "own account_sections" on public.account_sections;
create policy "own account_sections" on public.account_sections
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());


-- -- STEP 2: the three sections off the Net Worth sheet -----------------------
-- Skipped entirely if you already have account sections, so a second run cannot
-- undo your own reorganising.

with me as (select id from auth.users order by created_at limit 1)
insert into public.account_sections (user_id, name, sort_order)
select me.id, v.name, v.ord from me, (values
  ('Cash & Short Term Investments', 0),
  ('Retirement', 1),
  ('Real Estate', 2)
) as v(name, ord)
 where not exists (select 1 from public.account_sections s where s.user_id = me.id);


-- Assign the 17 imported accounts. Only fills a section that is still null, so
-- anything you have already moved by hand stays put.
with me as (select id from auth.users order by created_at limit 1),
     d(acct, section) as (values
  ('Savings',                   'Cash & Short Term Investments'),
  ('Ally Investment',           'Cash & Short Term Investments'),
  ('Car Savings',               'Cash & Short Term Investments'),
  ('Ed Jones Investment',       'Cash & Short Term Investments'),
  ('Coinbase',                  'Cash & Short Term Investments'),
  ('HSA Account',               'Cash & Short Term Investments'),
  ('Robinhood',                 'Cash & Short Term Investments'),
  ('iThink Checking',           'Cash & Short Term Investments'),
  ('Vacation Checking/Savings', 'Cash & Short Term Investments'),
  ('Publix Shareholder',        'Retirement'),
  ('Publix 401K',               'Retirement'),
  ('IRAs',                      'Retirement'),
  ('Vanguard',                  'Retirement'),
  ('529 Plans',                 'Retirement'),
  ('Vanguard Alliance 401K',    'Retirement'),
  ('House Zestimate',           'Real Estate'),
  ('House Balance',             'Real Estate')
)
update public.accounts a
   set section_id = s.id
  from d, me, public.account_sections s
 where a.user_id = me.id
   and s.user_id = me.id
   and lower(a.name) = lower(d.acct)
   and s.name = d.section
   and a.section_id is null;


-- ============================================================================
-- DONE. Check the split — 9 / 6 / 2, and nothing stranded:
--
--   select coalesce(s.name, '(no section)') as section, count(*)
--     from public.accounts a
--     left join public.account_sections s on s.id = a.section_id
--    group by 1 order by min(coalesce(s.sort_order, 99));
--
-- And that Real Estate now nets to the equity, which is what the sheet's Real
-- Estate Subtotal row was working out by hand:
--
--   select s.name,
--          sum(case when a.kind = 'asset' then b.balance else -b.balance end) as net
--     from public.accounts a
--     join public.account_sections s on s.id = a.section_id
--     join public.account_balances b on b.account_id = a.id
--    where b.as_of = (select max(as_of) from public.account_balances)
--    group by s.name, s.sort_order order by s.sort_order;
--
-- The three nets still add up to the same total as before. Grouping changed;
-- the arithmetic did not.
-- ============================================================================
