-- ============================================================================
-- Public athlete signup support
-- Parents fill out signup.html (no auth) and the row lands in athletes.
-- Auto-approve = on for the initial launch (active=true). Later, switch to
-- manual review by changing the RLS policy below (see notes at bottom).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Extra columns on athletes for the signup data
-- ---------------------------------------------------------------------------

alter table athletes
  add column if not exists date_of_birth          date,
  add column if not exists parent_first_name      text,
  add column if not exists parent_last_name       text,
  add column if not exists parent_email           text,
  add column if not exists parent_phone           text,
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_phone text,
  add column if not exists signup_notes           text,
  add column if not exists signup_source          text not null default 'manual'
                                                  check (signup_source in ('manual','self'));

create index if not exists athletes_signup_recent_idx
  on athletes (created_at desc)
  where signup_source = 'self';

-- ---------------------------------------------------------------------------
-- Allow anonymous signups (auto-approved for now).
-- The "with check" pins down what an unauthenticated submission can do:
--   * cannot claim someone else's auth_user_id
--   * goes in as signup_source = 'self'
--   * goes in as active = true   <-- flip to false later for manual review
--   * must include a parent email (small friction against bots)
-- ---------------------------------------------------------------------------

create policy "anon can self signup" on athletes
  for insert
  to anon
  with check (
    auth_user_id is null
    and active = true
    and signup_source = 'self'
    and parent_email is not null
  );

-- ============================================================================
-- When you want to switch to MANUAL REVIEW (later):
--   1) drop policy "anon can self signup" on athletes;
--   2) recreate it with `and active = false` in the with-check.
--   3) New signups land inactive; the coach reviews and flips them active.
-- (No code changes needed on the public form — it always writes active=true,
--  but the policy will reject and we'll need to update the form to send
--  active=false at that point too.)
-- ============================================================================
