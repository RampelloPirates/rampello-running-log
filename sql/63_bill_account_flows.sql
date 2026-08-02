-- ============================================================================
-- Where a bill's money comes from, and where it goes
--
-- Run in the Supabase SQL Editor, after 62. Safe to run more than once.
--
-- A bill has had one link since 57: account_id, described as "pays down" and
-- offered only for liabilities. That was too narrow in both directions.
--
-- Too narrow on WHAT it can point at. 529 Funds leaves the account every month
-- and lands in the 529 Plans balance. That is the same relationship the mortgage
-- has with House Balance — money arrives at an account — and the only
-- difference is that one account is an asset and the other a liability, which
-- decides whether the balance rises or falls. accounts.kind already knows that.
-- So the column is renamed to_account_id and the picker stops filtering.
--
-- Too narrow in DIRECTION. BMW is paid out of Car Savings; the mortgage is paid
-- out of the current account. Which account a bill drains was not recordable at
-- all, so from_account_id is new.
--
-- A bill can now have neither, either or both:
--   Electric        from: iThink Checking   to: —                (an expense)
--   Mortgage        from: iThink Checking   to: House Balance    (pays down)
--   529 Funds       from: iThink Checking   to: 529 Plans        (funds an asset)
--   BMW             from: Car Savings       to: —                (drains savings)
--
-- WHAT THIS DOES NOT DO, DELIBERATELY
-- -----------------------------------
-- It does not move any balance. account_balances rows are typed once a month
-- off real statements, and that is the ground truth — a statement already
-- includes the 529 contribution and the BMW payment. Having the app also add
-- and subtract them would double-count against the very figure being entered,
-- and the two would drift apart with no way to tell which was wrong.
--
-- So these links are description, not bookkeeping. They let the app say "+$300
-- a month from 529 Funds" beside the 529 Plans balance, which is the question
-- worth answering — why is this account moving — without pretending to be a
-- ledger it is not.
-- ============================================================================


-- -- STEP 1: rename account_id -> to_account_id ------------------------------
-- Guarded on both sides so a second run is a no-op rather than an error.

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'bills'
                and column_name = 'account_id')
     and not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'bills'
                and column_name = 'to_account_id')
  then
    alter table public.bills rename column account_id to to_account_id;
  end if;
end $$;


-- -- STEP 2: the new direction ------------------------------------------------
-- on delete set null on both: deleting an account is a change of mind about
-- what you track, never a reason to lose a bill or its payment history.

alter table public.bills
  add column if not exists from_account_id uuid references public.accounts(id) on delete set null;

create index if not exists bills_from_account_idx on public.bills (from_account_id);
create index if not exists bills_to_account_idx   on public.bills (to_account_id);


-- -- STEP 3: the two links you already know about ---------------------------
-- Only fills a link that is still null, so anything set in the app stays.

with me as (select id from auth.users order by created_at limit 1),
     d(bill, direction, acct) as (values
  ('529 Funds', 'to',   '529 Plans'),
  ('BMW',       'from', 'Car Savings')
)
update public.bills b
   set to_account_id   = case when d.direction = 'to'   then a.id else b.to_account_id   end,
       from_account_id = case when d.direction = 'from' then a.id else b.from_account_id end
  from d, me, public.accounts a
 where b.user_id = me.id
   and a.user_id = me.id
   and lower(b.name) = lower(d.bill)
   and lower(a.name) = lower(d.acct)
   and (   (d.direction = 'to'   and b.to_account_id   is null)
        or (d.direction = 'from' and b.from_account_id is null));


-- ============================================================================
-- DONE. Read the flows back:
--
--   select b.name,
--          f.name as paid_from,
--          t.name as pays_to,
--          case when t.kind = 'asset' then 'funds it' else 'pays it down' end as effect,
--          b.amount_default
--     from public.bills b
--     left join public.accounts f on f.id = b.from_account_id
--     left join public.accounts t on t.id = b.to_account_id
--    where b.active and (b.from_account_id is not null or b.to_account_id is not null)
--    order by b.name;
--
-- Expect three: Mortgage -> House Balance (pays it down), 529 Funds -> 529
-- Plans (funds it), and BMW paid from Car Savings. Mortgage carries over from
-- 59 because the column was renamed rather than replaced.
--
-- Everything else is yours to set in the app, on each bill, under Paid from and
-- Pays to. Nothing is required — most bills are just an expense and point at
-- neither.
-- ============================================================================
