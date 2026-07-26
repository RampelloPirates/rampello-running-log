-- ============================================================================
-- The wall display's identity
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- A screen on the kitchen wall is not a person. Signing it in as one would
-- hand everyone who walks past that person's entire health history — which is
-- the reason display_tokens has existed, unused, since 34.
--
-- Three functions, all SECURITY DEFINER, all reached with a token rather than
-- a session:
--
--   create_display_token  — admin only. Returns the secret ONCE.
--   wall_snapshot         — everything one screen needs, in one call.
--   wall_complete         — tick a chore from the wall.
--
-- The token is stored as a SHA-256 hash, so a leak of this table doesn't hand
-- anyone a working display. It's shown once at creation and never again;
-- losing it means issuing another, which is the correct trade for a string
-- that is pasted into a device once and then forgotten.
--
-- What the snapshot deliberately does NOT return
-- ----------------------------------------------
-- Columns are listed one by one rather than to_jsonb(t), so adding a column
-- somewhere else can never silently start publishing it to a screen in a
-- shared room. Money is the specific omission: extra_cents and everything
-- allowance-shaped stays out, the same rule the app follows by keeping
-- dollars on the To-dos tab. Points are fine — kids already see those.
--
-- Health tables aren't excluded here because they were never household-scoped
-- to begin with. There is no join from a display token to a lab result.
-- ============================================================================

-- ── Issue a token ──────────────────────────────────────────────────────────
create or replace function public.create_display_token(p_household uuid, p_label text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  tok text;
begin
  if not public.is_household_admin(p_household) then
    raise exception 'Only a household admin can add a display';
  end if;
  -- Two UUIDs' worth of randomness, so this needs no extension to be present.
  tok := replace(gen_random_uuid()::text, '-', '') ||
         replace(gen_random_uuid()::text, '-', '');
  insert into public.display_tokens (household_id, label, token_hash, created_by)
  values (p_household,
          coalesce(nullif(btrim(p_label), ''), 'Wall display'),
          encode(sha256(convert_to(tok, 'utf8')), 'hex'),
          auth.uid());
  return tok;
end;
$$;

grant execute on function public.create_display_token(uuid, text) to authenticated;

-- ── Everything one screen needs ────────────────────────────────────────────
create or replace function public.wall_snapshot(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token_id uuid;
  v_hh       uuid;
  v_out      jsonb;
begin
  select id, household_id into v_token_id, v_hh
    from public.display_tokens
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if v_hh is null then
    return null;                       -- unknown token: say nothing at all
  end if;

  update public.display_tokens set last_seen_at = now() where id = v_token_id;

  select jsonb_build_object(
    'household', (select jsonb_build_object('name', h.name, 'time_zone', h.time_zone)
                    from public.households h where h.id = v_hh),
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', m.id, 'display_name', m.display_name,
                  'color', m.color, 'role', m.role) order by m.sort_order), '[]'::jsonb)
                  from public.household_members m
                 where m.household_id = v_hh and m.active),
    -- Series come back whole; the page expands them, same as the app.
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', e.id, 'title', e.title, 'location', e.location,
                 'all_day', e.all_day, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
                 'start_date', e.start_date, 'end_date', e.end_date,
                 'rrule', e.rrule, 'exdates', e.exdates,
                 'attendee_ids', e.attendee_ids, 'color', e.color, 'kind', e.kind)), '[]'::jsonb)
                 from public.events e
                where e.household_id = v_hh
                  and (e.rrule is not null
                       or coalesce(e.end_date, e.start_date) >= current_date - 1
                       or e.starts_at >= (current_date - 1)::timestamptz)),
    -- No extra_cents. A screen in a shared room doesn't show money.
    'chores', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', c.id, 'title', c.title, 'kind', c.kind,
                 'assignee_ids', c.assignee_ids, 'rrule', c.rrule,
                 'starts_on', c.starts_on, 'time_of_day', c.time_of_day,
                 'repeatable', c.repeatable)), '[]'::jsonb)
                 from public.chores c
                where c.household_id = v_hh and c.active),
    'completions', (select coalesce(jsonb_agg(jsonb_build_object(
                      'chore_id', cc.chore_id, 'member_id', cc.member_id,
                      'due_on', cc.due_on)), '[]'::jsonb)
                      from public.chore_completions cc
                     where cc.household_id = v_hh
                       and cc.due_on >= current_date - 7),
    'meals', (select coalesce(jsonb_agg(jsonb_build_object(
                'plan_date', mp.plan_date, 'slot', mp.slot,
                'title', mp.title, 'venue', mp.venue)), '[]'::jsonb)
                from public.meal_plan mp
               where mp.household_id = v_hh
                 and mp.plan_date between current_date and current_date + 6),
    'server_date', to_jsonb(current_date)
  ) into v_out;

  return v_out;
end;
$$;

grant execute on function public.wall_snapshot(text) to anon, authenticated;

-- ── Tick a chore from the wall ─────────────────────────────────────────────
-- Mirrors the app's rule: everyone the chore belongs to gets credited, each at
-- their own tier's value. A chore assigned to nobody is refused rather than
-- guessed at — the wall has no "me" to fall back on, and crediting an
-- arbitrary member would be worse than declining.
create or replace function public.wall_complete(p_token text, p_chore uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hh    uuid;
  v_chore public.chores%rowtype;
  v_mid   uuid;
  v_pts   integer;
  v_today date := current_date;
begin
  select household_id into v_hh from public.display_tokens
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if v_hh is null then return null; end if;

  select * into v_chore from public.chores
   where id = p_chore and household_id = v_hh and active;
  if not found then return null; end if;
  if v_chore.kind = 'extra' then return null; end if;         -- extras pay cash
  if coalesce(array_length(v_chore.assignee_ids, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'unassigned');
  end if;

  -- Toggle: a second tap clears the occurrence for everyone on it.
  if exists (select 1 from public.chore_completions
              where chore_id = p_chore and due_on = v_today) then
    delete from public.chore_completions where chore_id = p_chore and due_on = v_today;
    return jsonb_build_object('ok', true, 'done', false);
  end if;

  foreach v_mid in array v_chore.assignee_ids loop
    select coalesce(
      (select bp.points from public.bucket_points bp
        where bp.bucket_id = v_chore.bucket_id and bp.member_id = v_mid),
      (select b.points from public.point_buckets b where b.id = v_chore.bucket_id),
      v_chore.points, 0) into v_pts;
    insert into public.chore_completions
      (household_id, chore_id, member_id, due_on, points_earned, completed_by)
    values (v_hh, p_chore, v_mid, v_today, v_pts, null)
    on conflict do nothing;
  end loop;

  return jsonb_build_object('ok', true, 'done', true);
end;
$$;

grant execute on function public.wall_complete(text, uuid) to anon, authenticated;

-- ============================================================================
-- DONE. Issue a token for your household (as an admin, from the app's Family
-- tab — or here, substituting your household id):
--
--   select public.create_display_token('<household-id>', 'Kitchen');
--
-- Copy what it returns; it is not recoverable. Then confirm it reads:
--
--   select jsonb_pretty(public.wall_snapshot('<the token>'));
--
-- An unknown token must return null rather than an error, so a wrong token
-- looks like no data instead of confirming the endpoint exists:
--
--   select public.wall_snapshot('not-a-real-token') is null;
-- ============================================================================
