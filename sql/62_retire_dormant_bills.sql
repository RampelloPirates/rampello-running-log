-- ============================================================================
-- Retire the five bills that have stopped happening
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- This is DATA, not a migration. It does by hand, for five bills at once, what
-- the Retire button in the app does one at a time — and it is written to match
-- that behaviour exactly rather than approximately, so the app and the database
-- never disagree about what "retired" means.
--
-- WHICH FIVE, AND WHY
-- -------------------
-- Each of these has had no non-zero figure in the last six months of the
-- spreadsheet (Jan–Jun 2026):
--
--   Health Insurance     last real figure well before 2026
--   Appliances           ran to 0 and stopped
--   Tires                ran to 0 and stopped
--   Rent                 ran 737 -> 1,328 -> 2,656 -> 0 and stopped
--   Other cards          the catch-all row; never populated recently
--
-- BMW is deliberately NOT in this list even though its recent figures are 0.
-- A car loan reaching zero is a loan being paid off, which is a different event
-- from a bill going away, and it is worth a look before it disappears.
--
-- WHAT RETIRING KEEPS
-- -------------------
-- Everything that records money actually moving. Three kinds of row, and the
-- line between them is the whole point:
--
--   * A PAID row, in any month, is untouched. Deleting one would change what a
--     past month cost, which is the one thing retiring must never do.
--   * An UNPAID row in a PAST month is untouched. It most likely means the bill
--     genuinely went unpaid that month, which is a fact about the past.
--   * An UNPAID row from THIS month forward is deleted. It holds nothing but an
--     expectation, and retiring the bill is precisely the withdrawal of it.
--
-- The bills themselves are never deleted, so every past month still resolves
-- its rows to a name and reads exactly as it did before.
-- ============================================================================


-- -- STEP 1: look before you leap ------------------------------------------
-- Run this on its own first. It shows what the statements below will touch —
-- nothing is changed by running it.
--
--   with me as (select id from auth.users order by created_at limit 1),
--        target(name) as (values ('Health Insurance'),('Appliances'),('Tires'),
--                                ('Rent'),('Other cards'))
--   select b.name,
--          b.active                                                as active_now,
--          count(*) filter (where p.paid_on is not null)            as paid_rows_kept,
--          count(*) filter (where p.paid_on is null
--                             and p.period <  date_trunc('month', current_date)::date) as unpaid_past_kept,
--          count(*) filter (where p.paid_on is null
--                             and p.period >= date_trunc('month', current_date)::date) as will_be_deleted,
--          max(p.period) filter (where p.paid_on is not null)       as last_actually_paid
--     from public.bills b
--     join me on b.user_id = me.id
--     join target t on lower(t.name) = lower(b.name)
--     left join public.bill_payments p on p.bill_id = b.id
--    group by b.name, b.active
--    order by b.name;
--
-- Expect five rows. If a name comes back missing, it has been renamed in the
-- app — fix the list below to match before running STEP 2.


-- -- STEP 2: drop the placeholder rows --------------------------------------
-- Deliberately BEFORE the flag is flipped, so that re-running this file is a
-- no-op rather than a second pass over a different set of rows.

with me as (select id from auth.users order by created_at limit 1),
     target(name) as (values ('Health Insurance'),('Appliances'),('Tires'),
                             ('Rent'),('Other cards'))
delete from public.bill_payments p
 using public.bills b, me, target t
 where p.bill_id = b.id
   and b.user_id = me.id
   and p.user_id = me.id
   and lower(b.name) = lower(t.name)
   and p.paid_on is null
   and p.period >= date_trunc('month', current_date)::date;


-- -- STEP 3: retire them -----------------------------------------------------

with me as (select id from auth.users order by created_at limit 1),
     target(name) as (values ('Health Insurance'),('Appliances'),('Tires'),
                             ('Rent'),('Other cards'))
update public.bills b
   set active = false
  from me, target t
 where b.user_id = me.id
   and lower(b.name) = lower(t.name)
   and b.active;


-- ============================================================================
-- DONE. Five retired, and the monthly list drops from 24 to 19:
--
--   select count(*) filter (where active)     as still_active,
--          count(*) filter (where not active) as retired
--     from public.bills;
--
-- Confirm the history survived — every one of these should still show the
-- months it was actually paid:
--
--   select b.name, count(*) as months_recorded,
--          min(p.period) as first, max(p.period) as last
--     from public.bills b
--     join public.bill_payments p on p.bill_id = b.id
--    where not b.active
--    group by b.name order by b.name;
--
-- And that no past month changed what it cost. Compare a month from before the
-- retirement against what you remember of it:
--
--   select period, sum(coalesce(amount_paid, amount_due)) as month_total
--     from public.bill_payments
--    where period between date '2026-01-01' and date '2026-06-01'
--    group by period order by period;
--
-- TO UNDO: the deleted rows were placeholders, so bringing the bills back is
-- the whole of it. The app's Reactivate button re-creates the current month's
-- row for one bill; this does the flag for all five at once.
--
--   update public.bills set active = true
--    where name in ('Health Insurance','Appliances','Tires','Rent','Other cards');
-- ============================================================================
