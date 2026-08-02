-- ============================================================================
-- Sections, and how a bill gets paid
--
-- Run in the Supabase SQL Editor, after 57/58/59. Safe to run more than once.
--
-- Two things the spreadsheet had that the first cut dropped.
--
-- SECTIONS
-- --------
-- The old sheet grouped its expenses into Cash Expenses, Credit Card Expenses
-- and All Other Expenses, each with its own subtotal. That grouping is not
-- derivable from anything already stored — it is not the category, and it is
-- not how the bill is paid — it is simply how the household thinks about its
-- money, and that is reason enough to keep it.
--
-- A table rather than a text column on bills. Three reasons: renaming a section
-- is one row instead of twenty-four, the order they appear in is a property of
-- the section rather than something re-derived from an alphabetical accident,
-- and a typo can't silently create a fourth section that looks like a third.
--
-- HOW IT IS PAID
-- --------------
-- bills.pay_method, not a link to an account. The question being answered is
-- "does this go on a card?" and the answer does not need to name the card: the
-- individual purchases on it were never itemised in the spreadsheet and are not
-- itemised here either. An FK to accounts would have demanded a row per card
-- and a balance nobody tracks, to store one bit of information.
--
-- 'bank' is the default because it is what a bill is unless told otherwise, and
-- because it makes this migration a no-op for every row that already exists.
--
-- Note the direction: a bill in the Credit Card Expenses section is the card
-- payment itself, which leaves the bank. It is the water bill sitting on a card
-- that is pay_method 'card'. The section and the method are different facts and
-- STEP 2 deliberately does not infer one from the other.
-- ============================================================================


create table if not exists public.bill_sections (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.bills
  -- on delete set null: deleting a section is a change of mind about grouping,
  -- never a reason to lose the bills or their payment history.
  add column if not exists section_id uuid references public.bill_sections(id) on delete set null,
  add column if not exists pay_method text not null default 'bank'
    check (pay_method in ('bank', 'card', 'cash'));

create index if not exists bill_sections_user_idx on public.bill_sections (user_id, sort_order);
create index if not exists bills_section_idx      on public.bills (section_id);

alter table public.bill_sections enable row level security;

drop policy if exists "own bill_sections" on public.bill_sections;
create policy "own bill_sections" on public.bill_sections
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());


-- -- STEP 2: the three sections off the spreadsheet ---------------------------
-- Names and membership taken from the row blocks of the Surplus-Deficit sheet,
-- so the app opens grouped the way the file was. Rename or reorder them in
-- Manage sections afterwards — nothing below depends on these names.
--
-- Skipped entirely if you already have sections, so this cannot undo your own
-- reorganising on a second run.

with me as (select id from auth.users order by created_at limit 1)
insert into public.bill_sections (user_id, name, sort_order)
select me.id, v.name, v.ord from me, (values
  ('Cash Expenses', 0),
  ('Credit Card Expenses', 1),
  ('All Other Expenses', 2)
) as v(name, ord)
 where not exists (select 1 from public.bill_sections s where s.user_id = me.id);


-- Assign the imported bills. Only fills a section that is still null, so a bill
-- you have already moved by hand stays where you put it.
with me as (select id from auth.users order by created_at limit 1),
     d(bill, section) as (values
  ('Mortgage',                 'Cash Expenses'),
  ('Electric',                 'Cash Expenses'),
  ('Health Insurance',         'Cash Expenses'),
  ('BMW',                      'Cash Expenses'),
  ('529 Funds',                'Cash Expenses'),
  ('Life Insurance',           'Cash Expenses'),
  ('Appliances',               'Cash Expenses'),
  ('Tires',                    'Cash Expenses'),
  ('Rent',                     'Cash Expenses'),
  ('Treadmill',                'Cash Expenses'),
  ('Chase',                    'Credit Card Expenses'),
  ('Citi - American Airlines', 'Credit Card Expenses'),
  ('Savor',                    'Credit Card Expenses'),
  ('Quicksilver',              'Credit Card Expenses'),
  ('Capital One Venture',      'Credit Card Expenses'),
  ('REI',                      'Credit Card Expenses'),
  ('Delta AMEX',               'Credit Card Expenses'),
  ('Banana Republic',          'Credit Card Expenses'),
  ('Other cards',              'Credit Card Expenses'),
  ('Water',                    'All Other Expenses'),
  ('Frontier',                 'All Other Expenses'),
  ('Medical Expenses',         'All Other Expenses'),
  ('Car Insurance',            'All Other Expenses'),
  ('Verizon',                  'All Other Expenses')
)
update public.bills b
   set section_id = s.id
  from d, me, public.bill_sections s
 where b.user_id = me.id
   and s.user_id = me.id
   and lower(b.name) = lower(d.bill)
   and s.name = d.section
   and b.section_id is null;


-- ============================================================================
-- DONE. Check the split — 10 / 9 / 5, and nothing stranded:
--
--   select coalesce(s.name, '(no section)') as section, count(*)
--     from public.bills b
--     left join public.bill_sections s on s.id = b.section_id
--    group by 1 order by min(coalesce(s.sort_order, 99));
--
-- Every bill starts as pay_method 'bank'. Tag the ones that actually sit on a
-- card in the app, or in bulk here if you would rather:
--
--   update public.bills set pay_method = 'card'
--    where name in ('Water', 'Frontier', 'Verizon');
-- ============================================================================
