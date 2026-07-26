-- ============================================================================
-- The wall can keep a list
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- "We're out of milk", typed on the fridge screen, is the reason a kitchen
-- display earns its place. It's also the only thing the wall can create
-- without inventing an identity it doesn't have: a chore needs an assignee
-- and a price, an event wants an author, and a list item needs nobody at all.
--
-- So lists are what the wall gets to write. checked_by stays null on anything
-- ticked from the wall — the display is not a person, and guessing which one
-- would be worse than admitting it.
--
-- The snapshot returns unchecked items plus anything ticked in the last six
-- hours, so an accidental tap can be undone from the screen it happened on
-- without the list filling up with a fortnight of shopping.
-- ============================================================================

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

-- ── Add an item ────────────────────────────────────────────────────────────
create or replace function public.wall_list_add(p_token text, p_list uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hh   uuid;
  v_body text := btrim(coalesce(p_body, ''));
  v_pos  integer;
begin
  select household_id into v_hh from public.display_tokens
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if v_hh is null or v_body = '' then return null; end if;

  if not exists (select 1 from public.lists
                  where id = p_list and household_id = v_hh) then
    return null;                       -- not this household's list
  end if;

  select coalesce(max(position), 0) + 1 into v_pos
    from public.list_items where list_id = p_list;

  insert into public.list_items (household_id, list_id, body, position)
  values (v_hh, p_list, left(v_body, 200), v_pos);

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.wall_list_add(text, uuid, text) to anon, authenticated;

-- ── Tick one off ───────────────────────────────────────────────────────────
-- checked_by stays null: the wall is a device, and recording a person who
-- wasn't identified would be a worse record than recording nobody.
create or replace function public.wall_list_toggle(p_token text, p_item uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hh  uuid;
  v_now boolean;
begin
  select household_id into v_hh from public.display_tokens
   where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'utf8')), 'hex');
  if v_hh is null then return null; end if;

  select checked into v_now from public.list_items
   where id = p_item and household_id = v_hh;
  if not found then return null; end if;

  update public.list_items
     set checked = not v_now,
         checked_at = case when v_now then null else now() end,
         checked_by = null
   where id = p_item;

  return jsonb_build_object('ok', true, 'checked', not v_now);
end;
$$;

grant execute on function public.wall_list_toggle(text, uuid) to anon, authenticated;

-- ============================================================================
-- DONE. Confirm the snapshot now carries lists, and that the event window
-- reaches far enough back for the month view to page into:
--
--   select jsonb_pretty(public.wall_snapshot('<the token>') -> 'lists');
--   select jsonb_array_length(public.wall_snapshot('<the token>') -> 'events');
--
-- A list from another household must be refused rather than written to:
--
--   select public.wall_list_add('<the token>', '<some other household list id>', 'x') is null;
-- ============================================================================
