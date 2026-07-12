-- ============================================================================
-- Mileage from the visit summary. Run in the Supabase SQL Editor. Safe to rerun.
--
-- The doctor's address is printed on the summary and your home address doesn't
-- change, so the round-trip mileage — a qualified HSA expense that almost nobody
-- claims — is derivable rather than something you have to remember to log.
-- ============================================================================

-- Where you drive from. Kept in settings, not hardcoded: people move, and a
-- claim computed from the wrong origin is worse than no claim.
alter table public.hsa_settings
  add column if not exists home_address text;

-- The address we measure TO. Read off the summary alongside everything else.
alter table public.medical_visits
  add column if not exists facility_address text;

-- One mileage claim per visit, not one per time you reopen the page. A partial
-- unique index is the cheapest way to make double-claiming structurally
-- impossible rather than merely discouraged.
create unique index if not exists medical_expenses_one_mileage_per_visit
  on public.medical_expenses (visit_id)
  where category = 'mileage' and visit_id is not null;

-- ============================================================================
-- DONE. Verify:
--   select v.visit_date, v.facility_address, e.miles, e.paid_amount
--   from public.medical_visits v
--   left join public.medical_expenses e
--     on e.visit_id = v.id and e.category = 'mileage';
-- ============================================================================
