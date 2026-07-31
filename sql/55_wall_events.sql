-- ============================================================================
-- The wall can keep the calendar too
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- 50_wall_lists said a list item was the only thing the wall could create,
-- because "a chore needs an assignee and a price, an event wants an author,
-- and a list item needs nobody at all". The author problem hasn't gone away —
-- it has been decided instead. An event added from the kitchen screen records
-- created_by = null, the same admission wall_list_toggle already makes about
-- checked_by: the display is a device, and naming a person who wasn't there
-- is a worse record than naming nobody.
--
-- What this means for who can do it
-- ---------------------------------
-- Anyone standing at the screen. The wall has no sign-in by design, so this
-- is the same trust boundary that already lets a passer-by tick a chore or
-- add to the shopping list — but a calendar is more consequential than a
-- shopping list, and that is worth saying out loud rather than discovering.
-- The mitigations are that the token is per-household and unguessable, that
-- nothing here can reach a personal health table, and that the destructive
-- operations below are deliberately narrow.
--
-- What the wall deliberately cannot do
-- ------------------------------------
--   * Create a repeating event. The recurrence picker is a fiddly control and
--     a wrong RRULE is a mess that shows up months later; it stays in the app.
--     Inserts here always write rrule = null.
--   * Retime a repeating event. Editing a series' title or attendees applies
--     cleanly to every occurrence; moving its clock does not, and answering
--     "this one or all of them" needs a conversation a wall shouldn't host.
--     Updates to a row with an rrule touch only title, location, notes,
--     attendees and kind — enforced here, not merely hidden in the UI.
--   * Delete a series. wall_event_delete refuses one and says so. Cancelling a
--     single occurrence is what a kitchen actually needs ("no practice this
--     week"), and wall_event_skip does that through exdates.
--
-- The snapshot also starts returning events.notes, which the detail view needs.
-- That is a deliberate publish decision, not an oversight: notes on a family
-- calendar are "bring cleats, £20 for the coach", which is the whole reason
-- somebody taps an event to read it. Columns here are still listed one by one
-- so nothing else follows it out by accident.
-- ============================================================================

-- ── Snapshot: carry notes ──────────────────────────────────────────────────
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
    -- Series come back whole; the page expands them, same as the app. The
    -- window is wide because the wall can now be paged to another month.
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', e.id, 'title', e.title, 'location', e.location,
                 'notes', e.notes,
                 'all_day', e.all_day, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
                 'start_date', e.start_date, 'end_date', e.end_date,
                 'rrule', e.rrule, 'exdates', e.exdates,
                 'attendee_ids', e.attendee_ids, 'color', e.color, 'kind', e.kind)), '[]'::jsonb)
                 from public.events e
                where e.household_id = v_hh
                  and (e.rrule is not null
                       or coalesce(e.end_date, e.start_date) >= current_date - 45
                       or e.starts_at >= (current_date - 45)::timestamptz)),
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
                 and mp.plan_date between current_date - 1 and current_date + 45),
    'lists', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', l.id, 'name', l.name, 'kind', l.kind)
                order by l.sort_order), '[]'::jsonb)
                from public.lists l where l.household_id = v_hh),
    -- Outstanding items, plus anything ticked recently so a mis-tap can be
    -- undone from the screen it happened on.
    'list_items', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', i.id, 'list_id', i.list_id, 'body', i.body,
                     'checked', i.checked, 'position', i.position)
                     order by i.checked, i.position), '[]'::jsonb)
                     from public.list_items i
                    where i.household_id = v_hh
                      and (not i.checked or i.checked_at > now() - interval '6 hours')),
    'server_date', to_jsonb(current_date)
  ) into v_out;

  return v_out;
end;
$$;

grant execute on function public.wall_snapshot(text) to anon, authenticated;

-- ── Add or change one ──────────────────────────────────────────────────────
-- The time shape is built here rather than trusted from the client: the
-- events_time_shape constraint makes the mixed form unrepresentable, and the
-- honest way to satisfy it is to pick a branch from p_all_day and null the
-- other side outright. A client that sends both gets the coherent one.
create or replace function public.wall_event_save(
  p_token      text,
  p_id         uuid,
  p_title      text,
  p_location   text,
  p_notes      text,
  p_all_day    boolean,
  p_start_date date,
  p_end_date   date,
  p_starts_at  timestamptz,
  p_ends_at    timestamptz,
  p_attendees  uuid[],
  p_kind       text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hh    uuid;
  v_ev    public.events%rowtype;
  v_title text := btrim(coalesce(p_title, ''));
  v_kind  text := case when p_kind = 'travel' then 'travel' else 'in_town' end;
  v_all   boolean := coalesce(p_all_day, false);
  v_sd    date;
  v_ed    date;
  v_sa    timestamptz;
  v_ea    timestamptz;
  v_att   uuid[];
  v_id    uuid;
begin
  select household_id into v_hh from public.display_tokens
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if v_hh is null then return null; end if;

  if v_title = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_title');
  end if;

  -- Attendee ids arrive from a screen anyone can touch, so they are filtered
  -- to this household's own members rather than written as given. The column
  -- has no FK (Postgres can't reference from an array), which makes this the
  -- only thing standing between a typo and a dangling id.
  select coalesce(array_agg(m.id), '{}')::uuid[] into v_att
    from unnest(coalesce(p_attendees, '{}')::uuid[]) as a(id)
    join public.household_members m
      on m.id = a.id and m.household_id = v_hh and m.active;

  if v_all then
    v_sd := coalesce(p_start_date, current_date);
    v_ed := greatest(coalesce(p_end_date, v_sd), v_sd);   -- end_date is inclusive
    v_sa := null; v_ea := null;
  else
    if p_starts_at is null then
      return jsonb_build_object('ok', false, 'reason', 'no_time');
    end if;
    v_sa := p_starts_at;
    v_ea := greatest(coalesce(p_ends_at, v_sa), v_sa);
    v_sd := null; v_ed := null;
  end if;

  if p_id is not null then
    select * into v_ev from public.events
     where id = p_id and household_id = v_hh;
    if not found then return null; end if;

    if v_ev.rrule is not null then
      -- A series: only the fields that mean the same thing on every occurrence.
      update public.events
         set title = left(v_title, 200),
             location = nullif(btrim(coalesce(p_location, '')), ''),
             notes = nullif(btrim(coalesce(p_notes, '')), ''),
             attendee_ids = v_att,
             kind = v_kind,
             updated_at = now()
       where id = p_id;
      return jsonb_build_object('ok', true, 'id', p_id, 'series', true);
    end if;

    update public.events
       set title = left(v_title, 200),
           location = nullif(btrim(coalesce(p_location, '')), ''),
           notes = nullif(btrim(coalesce(p_notes, '')), ''),
           all_day = v_all,
           start_date = v_sd, end_date = v_ed,
           starts_at = v_sa, ends_at = v_ea,
           attendee_ids = v_att,
           kind = v_kind,
           updated_at = now()
     where id = p_id;
    return jsonb_build_object('ok', true, 'id', p_id, 'series', false);
  end if;

  -- New. rrule stays null: the wall does not author recurrence.
  insert into public.events
    (household_id, title, location, notes, all_day,
     start_date, end_date, starts_at, ends_at,
     time_zone, kind, attendee_ids, rrule, created_by)
  values
    (v_hh, left(v_title, 200),
     nullif(btrim(coalesce(p_location, '')), ''),
     nullif(btrim(coalesce(p_notes, '')), ''),
     v_all, v_sd, v_ed, v_sa, v_ea,
     (select time_zone from public.households where id = v_hh),
     v_kind, v_att, null, null)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'created', true);
end;
$$;

grant execute on function public.wall_event_save(
  text, uuid, text, text, text, boolean, date, date,
  timestamptz, timestamptz, uuid[], text) to anon, authenticated;

-- ── Remove a one-off ───────────────────────────────────────────────────────
-- A series is refused with a reason rather than silently ignored, so the wall
-- can say why instead of appearing to have done nothing.
create or replace function public.wall_event_delete(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hh uuid;
  v_rr text;
begin
  select household_id into v_hh from public.display_tokens
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if v_hh is null then return null; end if;

  select rrule into v_rr from public.events
   where id = p_id and household_id = v_hh;
  if not found then return null; end if;

  if v_rr is not null then
    return jsonb_build_object('ok', false, 'reason', 'recurring');
  end if;

  delete from public.events where id = p_id and household_id = v_hh;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.wall_event_delete(text, uuid) to anon, authenticated;

-- ── Cancel one occurrence of a series ──────────────────────────────────────
-- Appends to exdates, the same mechanism family.html's "Just Tuesday" uses.
-- The timestamp is local midnight in the HOUSEHOLD's zone, because that is
-- what the expander compares against after converting back to a local date.
create or replace function public.wall_event_skip(p_token text, p_id uuid, p_day date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hh uuid;
  v_tz text;
  v_rr text;
  v_ts timestamptz;
begin
  select household_id into v_hh from public.display_tokens
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if v_hh is null or p_day is null then return null; end if;

  select rrule into v_rr from public.events
   where id = p_id and household_id = v_hh;
  if not found then return null; end if;
  if v_rr is null then
    return jsonb_build_object('ok', false, 'reason', 'not_recurring');
  end if;

  select time_zone into v_tz from public.households where id = v_hh;
  v_ts := (p_day::text || ' 00:00')::timestamp at time zone coalesce(v_tz, 'America/New_York');

  -- Skipping the same day twice must not grow the array forever.
  update public.events
     set exdates = (select array_agg(distinct x)
                      from unnest(array_append(exdates, v_ts)) as t(x)),
         updated_at = now()
   where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.wall_event_skip(text, uuid, date) to anon, authenticated;

-- ============================================================================
-- DONE. With a real token in hand:
--
--   -- notes now come across
--   select public.wall_snapshot('<token>') -> 'events' -> 0 ? 'notes';
--
--   -- add one, and read back what it wrote
--   select public.wall_event_save('<token>', null, 'Dentist', 'Main St', null,
--            false, null, null, now() + interval '1 day',
--            now() + interval '1 day 30 minutes', '{}'::uuid[], 'in_town');
--
--   -- an empty title is refused rather than stored
--   select public.wall_event_save('<token>', null, '   ', null, null,
--            true, current_date, null, null, null, '{}'::uuid[], 'in_town');
--
--   -- a series refuses deletion and says why
--   select public.wall_event_delete('<token>',
--            (select id from public.events where rrule is not null limit 1));
--
-- An event belonging to another household must be untouchable, returning null
-- rather than an error:
--
--   select public.wall_event_delete('<token>', '<some other household event id>') is null;
--
-- And the wall's own additions are authorless by design:
--
--   select title, created_by is null as authorless
--     from public.events where household_id = '<hh>' order by created_at desc limit 5;
-- ============================================================================
