-- ============================================================================
-- Family members claim their own seat by email
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Adding someone to the household created a name and a colour, and there was
-- no way to attach a login to it. household_members.user_id existed and
-- nothing ever set it, so the only route was an UPDATE in this editor for
-- every person — and worse, anyone who signed in without a membership row was
-- shown "Set up your household" and could quietly create a second, empty one.
--
-- So: record the email when you add someone, and let them claim the row
-- themselves on first sign-in. Same self-provisioning shape the athletes table
-- has used since the personal pivot.
--
-- Why this has to be a function
-- -----------------------------
-- RLS on household_members is is_household_member(household_id), which is
-- false for the very person we're trying to admit — they can't see the row
-- that would make them a member. That's circular, and SECURITY DEFINER is the
-- way out, exactly as it is for the helpers in 34_household.
--
-- Why that's safe
-- ---------------
-- The function will only ever touch a row that is unclaimed (user_id is null)
-- and whose email matches the caller's own, taken from their JWT rather than
-- from anything they passed in. With magic-link sign-in that address is one
-- they demonstrably control. It cannot take a seat that already belongs to
-- someone, cannot be aimed at a household by id, and takes no arguments at
-- all — there is nothing to point at a row of your choosing.
-- ============================================================================

alter table public.household_members
  add column if not exists email text;

-- One invite per address per household. Partial, because most rows never get
-- an email at all — a small kid is a name on the wall and nothing more.
create unique index if not exists household_members_email_uniq
  on public.household_members (household_id, lower(email))
  where email is not null;

create or replace function public.claim_household_membership()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_email text;
  claimed      uuid;
begin
  if auth.uid() is null then
    return null;
  end if;

  caller_email := lower(nullif(auth.jwt() ->> 'email', ''));
  if caller_email is null then
    return null;
  end if;

  -- Already seated: hand back the existing membership rather than hunting for
  -- an invite. Makes the call idempotent, so the app can run it on every load.
  select id into claimed
    from public.household_members
   where user_id = auth.uid() and active
   order by created_at
   limit 1;
  if claimed is not null then
    return claimed;
  end if;

  -- Oldest matching invite wins, so a stray duplicate can't make this
  -- ambiguous or claim two rows at once.
  with target as (
    select id from public.household_members
     where lower(email) = caller_email
       and user_id is null
       and active
     order by created_at
     limit 1
  )
  update public.household_members m
     set user_id = auth.uid()
    from target t
   where m.id = t.id
  returning m.id into claimed;

  return claimed;
end;
$$;

grant execute on function public.claim_household_membership() to authenticated;

-- ============================================================================
-- DONE. Verify the function exists and is harmless when you're already seated
-- (it should return your own membership id, not claim anything):
--
--   select public.claim_household_membership();
--
-- To invite someone, set their email on the row — the app's member sheet does
-- this for you, but by hand it's:
--
--   update public.household_members
--      set email = 'emma@example.com'
--    where household_id = '<id>' and display_name = 'Emma';
--
-- They then sign in at /family.html and the seat attaches itself. Check with:
--
--   select display_name, email, user_id is not null as has_login
--   from public.household_members order by sort_order;
-- ============================================================================
