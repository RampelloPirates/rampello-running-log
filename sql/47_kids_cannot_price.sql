-- ============================================================================
-- Kids can add work. Only adults can say what it pays.
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Adding a chore is a good habit and there's no reason to gate it — noticing
-- the recycling needs doing is the behaviour you want. Pricing it is a
-- different act, and a child who can set their own rate has an allowance they
-- award themselves.
--
-- All three pay fields, not just the dollar one
-- ---------------------------------------------
-- extra_cents is the obvious one. But points convert to money by a fixed
-- ratio, and bucket_id chooses a points value, so "put my new chore in the
-- Big tier" is the same exploit wearing a different hat. All three are
-- adults-only or the rule has a hole in it.
--
-- A trigger rather than a policy, because the two operations want different
-- answers. On insert, a kid's chore simply arrives unpriced and waits for a
-- parent. On update, the fields are carried over from the existing row — a
-- WITH CHECK could only demand the new row be unpriced, which would stop a
-- kid renaming a chore a parent had already priced. Editing the title is
-- fine; editing the payout is not.
--
-- Silently preserving rather than raising: the app doesn't show a kid these
-- fields at all, so anything reaching here is either a stale page or someone
-- poking at the API. Neither deserves an error message, and both should
-- simply fail to have an effect.
-- ============================================================================

create or replace function public.guard_chore_pay_fields()
returns trigger
language plpgsql
as $$
begin
  if public.is_household_adult(new.household_id) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.points      := 0;
    new.extra_cents := 0;
    new.bucket_id   := null;
  else
    new.points      := old.points;
    new.extra_cents := old.extra_cents;
    new.bucket_id   := old.bucket_id;
  end if;
  return new;
end;
$$;

drop trigger if exists chores_guard_pay on public.chores;
create trigger chores_guard_pay
  before insert or update on public.chores
  for each row execute function public.guard_chore_pay_fields();

-- ============================================================================
-- DONE. The trigger is invisible to adults — verify it exists, then check it
-- from a kid's session (the app, signed in as one) by adding an extra and
-- confirming it saves with extra_cents = 0:
--
--   select tgname, tgenabled from pg_trigger where tgrelid = 'public.chores'::regclass;
--
--   select title, kind, points, extra_cents, bucket_id
--   from public.chores order by created_at desc limit 5;
--
-- Note this guards chores only. Tiers themselves (point_buckets,
-- bucket_points) are already behind the allocation screen, which is adult-
-- only in the app — worth revisiting if a kid ever needs a reason to open it.
-- ============================================================================
