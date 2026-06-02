-- ============================================================================
-- Add Coach Sowell (head coach). Email is a placeholder — update in Supabase
-- once the real address is known.
--
-- Idempotent: re-running is a no-op thanks to the unique email constraint.
-- ============================================================================

INSERT INTO coaches (first_name, last_name, email, role, active)
VALUES ('William', 'Sowell', 'sowell@piratesxc.test', 'head', true)
ON CONFLICT (email) DO NOTHING;
