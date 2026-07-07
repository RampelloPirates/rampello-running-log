-- ============================================================================
-- Vitals: note where a reading was taken — 'clinic' (doctor's office) vs 'home'.
-- Applies mainly to blood_pressure and weight, where the setting matters (white-
-- coat effect, scale differences). Run in the Supabase SQL Editor. Idempotent.
-- ============================================================================

alter table public.vitals add column if not exists context text;   -- 'clinic' | 'home' | null

-- Everything imported from the BayCare patient portal was taken at the office.
update public.vitals
set context = 'clinic'
where context is null
  and source ilike '%portal%'
  and kind in ('blood_pressure','weight');

-- ============================================================================
-- DONE. Verify:  select kind, context, count(*) from public.vitals
--                where kind in ('blood_pressure','weight')
--                group by kind, context order by kind;
-- ============================================================================
