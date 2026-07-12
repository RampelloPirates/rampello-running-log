-- ============================================================================
-- Medical, second pass. Run in the Supabase SQL Editor. Safe to run twice.
--
-- Two things the first version got wrong:
--
-- 1. ONE PHOTO PER RECORD. A visit summary is routinely three pages and an
--    itemised bill is worse. image_path could only hold one, so the rest of the
--    document was simply lost — which, for the half of this module whose entire
--    purpose is documentation, is the wrong thing to lose.
--
-- 2. NO LINK BETWEEN A VISIT AND WHAT IT COST. The visit summary says what you
--    OWE; the receipt says what you PAID. They're two halves of one transaction
--    and there was nothing joining them, so nothing could answer "which visits
--    do I still owe a receipt for?" — which is exactly the gap that loses you
--    an HSA claim years later.
-- ============================================================================

-- Every page of the document, in order. image_path stays as page one so nothing
-- already filed breaks.
alter table public.medical_visits
  add column if not exists image_paths text[],
  -- What the summary says the patient owes. The number the receipt should match.
  add column if not exists amount_owed numeric(10,2);

alter table public.medical_expenses
  add column if not exists image_paths text[];

-- medical_expenses.visit_id already exists (ON DELETE SET NULL) — an expense
-- outlives the visit record it came from. This index makes the reverse lookup
-- ("what did this visit cost me?") cheap.
create index if not exists medical_expenses_visit_idx
  on public.medical_expenses (visit_id) where visit_id is not null;

-- ============================================================================
-- DONE. Verify:
--   select v.visit_date, v.amount_owed,
--          coalesce(sum(e.paid_amount),0) as documented
--   from public.medical_visits v
--   left join public.medical_expenses e on e.visit_id = v.id
--   group by v.id, v.visit_date, v.amount_owed;
-- ============================================================================
