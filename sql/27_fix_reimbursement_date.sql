-- ============================================================================
-- One-off: correct the reimbursement date on the $1,693 dental charge.
--
-- It was marked reimbursed in the app, which stamped TODAY rather than the day
-- the money actually left the HSA (2025-10-01). The date matters: it's the
-- record of when the account was drawn against, and "the day I happened to tick
-- a box" is not that.
--
-- Run in the Supabase SQL Editor. Idempotent — safe to run twice.
-- ============================================================================

update public.medical_expenses
set    reimbursed    = true,
       reimbursed_on = date '2025-10-01'
where  paid_amount   = 1693.00
  and  service_date  = date '2025-09-02';

-- Verify:
--   select service_date, provider, paid_amount, reimbursed, reimbursed_on
--   from public.medical_expenses where paid_amount = 1693.00;
-- ============================================================================
