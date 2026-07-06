-- ============================================================================
-- Fix: portal lab markers were stored in Title Case ('Sodium') while Quest uses
-- UPPERCASE ('SODIUM'), so the same marker didn't trend as one line. Uppercase
-- the portal-sourced result names to match. One-off; safe to run more than once.
-- (The importer is also fixed going forward — see labs_sync/import_labs.py.)
-- ============================================================================

update public.lab_results lr
set name = upper(lr.name)
from public.lab_reports rep
where lr.report_id = rep.id
  and rep.source ilike 'BayCare%'
  and lr.name <> upper(lr.name);

-- Verify a marker now spans multiple dates:
--   select rep.collected_on, lr.value_num, lr.unit
--   from public.lab_results lr join public.lab_reports rep on rep.id = lr.report_id
--   where lr.name = 'SODIUM' order by rep.collected_on;
-- ============================================================================
