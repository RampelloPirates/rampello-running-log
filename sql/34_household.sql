-- ============================================================================
-- Household — the family side of the app: a shared calendar, chores, and lists.
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- The shape of the thing:
--   households        — one family. The scope everything below hangs off.
--   household_members — a person in it. Can exist before they have a login,
--                       so you can put the kids on the wall today and invite
--                       them later.
--   events            — the calendar. Modelled in iCalendar's shape from day
--                       one (see the sync note below).
--   chores            — a recurring job; chore_completions is who did it when.
--   lists             — grocery / todo / packing, and the items in them.
--   display_tokens    — how a wall-mounted screen authenticates. Not a person.
--
-- Why this doesn't touch anything that already exists
-- ---------------------------------------------------
-- 11_personal_pivot deliberately removed every multi-user construct: no
-- coaches, no roster, no shared rows. Every auth user owns their own runs and
-- nothing else. That decision stands. Health data — runs, labs, vitals,
-- medical_visits, hsa_settings — stays personal and is NOT household-scoped.
--
-- This is on purpose and it is the privacy boundary of the whole feature:
-- bloodwork and HSA receipts are exactly what must never render on a kitchen
-- wall. Because those tables have no household_id, a display token cannot
-- reach them by construction. That's a stronger guarantee than remembering
-- not to select them.
--
-- Why the sync columns exist before there is any sync
-- ---------------------------------------------------
-- Events are app-native for now; iCloud comes later. But if local events were
-- authoritative and iCloud arrived afterwards as a second source, there would
-- be two sources of truth and a genuine merge problem. Carrying uid / href /
-- etag / raw_ics now — nullable and unused — turns that later step into a
-- promotion instead: PUT each local event to CalDAV, record what comes back,
-- flip source. Nothing conflicts, because nothing else has ever touched them.
--
-- Generating a real iCal UID for every event today costs nothing and gives
-- each one a stable identity for that push. Without it you'd be matching on
-- title-and-timestamp later, which is as bad as it sounds.
-- ============================================================================

-- ── One family ─────────────────────────────────────────────────────────────
create table if not exists public.households (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  time_zone   text not null default 'America/New_York',
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- ── A person in it ─────────────────────────────────────────────────────────
-- user_id is nullable on purpose: a member is a name and a colour on the wall
-- first, and an account holder second (or never, for a small kid). Members
-- without a user_id simply grant no access — is_household_member() matches on
-- auth.uid(), so an unclaimed row is inert.
create table if not exists public.household_members (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  user_id       uuid references auth.users(id) on delete set null,
  display_name  text not null,
  color         text not null default '#4f7cff',
  role          text not null default 'adult' check (role in ('admin','adult','kid')),
  sort_order    integer not null default 0,
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

-- One row per person per household. Partial, because several members may sit
-- at null user_id while they wait for logins.
create unique index if not exists household_members_user_uniq
  on public.household_members (household_id, user_id)
  where user_id is not null;

create index if not exists household_members_household_idx
  on public.household_members (household_id, sort_order);

-- ── RLS helpers ────────────────────────────────────────────────────────────
-- SECURITY DEFINER for the same reason is_coach() was: these read
-- household_members, and household_members' own policy calls them. Without
-- the definer bypass that policy would recurse into itself forever.
create or replace function public.is_household_member(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.household_members
    where household_id = hid and user_id = auth.uid() and active = true
  );
$$;

-- Admin also covers the creator, which is what makes the first household
-- bootstrappable: you insert the household, then insert yourself into it, and
-- the second insert passes because you own the first row.
create or replace function public.is_household_admin(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.households h
    where h.id = hid and h.created_by = auth.uid()
  ) or exists (
    select 1 from public.household_members m
    where m.household_id = hid and m.user_id = auth.uid()
      and m.active = true and m.role = 'admin'
  );
$$;

grant execute on function public.is_household_member(uuid) to authenticated;
grant execute on function public.is_household_admin(uuid)  to authenticated;

-- ── The calendar ───────────────────────────────────────────────────────────
-- Timed and all-day events are genuinely different things and get different
-- columns. Storing an all-day event as midnight-to-midnight timestamps is the
-- single most reliable way to produce a calendar that drifts by a day across a
-- DST boundary, so the check constraint below makes that shape unrepresentable.
--
-- end_date is INCLUSIVE here — a one-day event has start_date = end_date. Note
-- that iCalendar's DTEND for all-day events is EXCLUSIVE, so whatever exports
-- ICS later must add a day. App reads vastly outnumber exports; the natural
-- shape belongs in the table.
create table if not exists public.events (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,

  -- iCal identity. Unused until sync lands; generated now so it's stable.
  uid           text not null default (gen_random_uuid()::text || '@jeff-tally.vercel.app'),

  title         text not null,
  location      text,
  notes         text,

  all_day       boolean not null default false,
  starts_at     timestamptz,          -- timed events only
  ends_at       timestamptz,
  start_date    date,                 -- all-day events only
  end_date      date,
  time_zone     text not null default 'America/New_York',

  -- RFC 5545 RRULE, without the "RRULE:" prefix — e.g. FREQ=WEEKLY;BYDAY=TU,TH.
  -- Only ever written by the app's own recurrence picker, so the subset stays
  -- small and expansion stays tractable.
  rrule         text,
  -- Cancelled single occurrences. Appending here suppresses one instance
  -- without modelling a per-instance override, which covers "practice is off
  -- this week" — the common case — for a fraction of the complexity of
  -- RECURRENCE-ID exception events. All-day series store midnight in time_zone.
  exdates       timestamptz[] not null default '{}',

  -- household_members.id values. No FK — Postgres can't reference from an
  -- array — so the app prunes these when a member is removed.
  attendee_ids  uuid[] not null default '{}',
  color         text,

  -- ── Sync columns: stubbed, see header ──
  source        text not null default 'local' check (source in ('local','icloud')),
  caldav_href   text,
  caldav_etag   text,
  raw_ics       text,

  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint events_time_shape check (
    (all_day     and start_date is not null and starts_at is null)
    or
    (not all_day and starts_at  is not null and start_date is null)
  ),
  constraint events_time_order check (
    (ends_at  is null or starts_at   is null or ends_at  >= starts_at) and
    (end_date is null or start_date is null or end_date >= start_date)
  )
);

-- Dedup on the iCal identity. When CalDAV events arrive carrying their own
-- UIDs this is what stops a re-sync from doubling the calendar.
create unique index if not exists events_uid_uniq
  on public.events (household_id, uid);

create index if not exists events_household_start_idx
  on public.events (household_id, starts_at);
create index if not exists events_household_date_idx
  on public.events (household_id, start_date);

-- Recurring series can't be range-indexed — they have to be fetched whole and
-- expanded. Keeping them behind a partial index makes that cheap.
create index if not exists events_recurring_idx
  on public.events (household_id)
  where rrule is not null;

create index if not exists events_attendees_idx
  on public.events using gin (attendee_ids);

-- ── Chores ─────────────────────────────────────────────────────────────────
-- Due dates are derived from rrule at read time, not pre-generated. A row per
-- occurrence forever is a table that only grows and a schedule you can never
-- change retroactively.
create table if not exists public.chores (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  title         text not null,
  notes         text,
  -- null = anyone in the household can claim it.
  assigned_to   uuid references public.household_members(id) on delete set null,
  rrule         text,
  starts_on     date not null default current_date,
  points        integer not null default 0,
  sort_order    integer not null default 0,
  active        boolean not null default true,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index if not exists chores_household_idx
  on public.chores (household_id, active, sort_order);

-- Lets the composite FK below point at (id, household_id).
create unique index if not exists chores_id_household_uniq
  on public.chores (id, household_id);

-- household_id is denormalised on purpose — it lets RLS answer from the row
-- itself instead of joining back through chores on every check.
--
-- The composite FK is what keeps that denormalisation honest. Without it, RLS
-- would happily accept a row carrying your own household_id while chore_id
-- pointed at someone else's chore: the WITH CHECK only ever inspects the
-- household_id column. Referencing (chore_id, household_id) together makes the
-- two agree by construction.
create table if not exists public.chore_completions (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  chore_id      uuid not null,
  member_id     uuid references public.household_members(id) on delete set null,
  due_on        date not null,
  completed_at  timestamptz not null default now(),

  foreign key (chore_id, household_id)
    references public.chores (id, household_id) on delete cascade
);

-- One completion per occurrence. Two kids tapping the same chore is a race,
-- not two chores done.
create unique index if not exists chore_completions_occurrence_uniq
  on public.chore_completions (chore_id, due_on);

create index if not exists chore_completions_household_idx
  on public.chore_completions (household_id, due_on desc);

-- ── Lists ──────────────────────────────────────────────────────────────────
create table if not exists public.lists (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  name          text not null,
  kind          text not null default 'todo'
                  check (kind in ('grocery','todo','packing','other')),
  color         text,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now()
);

create index if not exists lists_household_idx
  on public.lists (household_id, sort_order);

create unique index if not exists lists_id_household_uniq
  on public.lists (id, household_id);

-- Same composite-FK reasoning as chore_completions above.
create table if not exists public.list_items (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  list_id       uuid not null,
  body          text not null,
  checked       boolean not null default false,
  checked_by    uuid references public.household_members(id) on delete set null,
  checked_at    timestamptz,
  position      integer not null default 0,
  created_at    timestamptz not null default now(),

  foreign key (list_id, household_id)
    references public.lists (id, household_id) on delete cascade
);

create index if not exists list_items_list_idx
  on public.list_items (list_id, checked, position);

-- ── How a wall screen signs in ─────────────────────────────────────────────
-- A display is not a person. Giving a wall tablet somebody's login would hand
-- whoever walks past it that person's entire health history; this table is how
-- that's avoided.
--
-- Only the hash is stored — the token itself is shown once, at creation, and
-- pasted into the display. The read path is a SECURITY DEFINER RPC that takes
-- a token and returns just this household's calendar/chores/lists, which lands
-- with wall.html. Deliberately nothing here grants table-level access.
create table if not exists public.display_tokens (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  label         text not null default 'Wall display',
  token_hash    text not null,
  last_seen_at  timestamptz,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

create unique index if not exists display_tokens_hash_uniq
  on public.display_tokens (token_hash);

-- ── RLS: membership is the boundary ────────────────────────────────────────
alter table public.households        enable row level security;
alter table public.household_members enable row level security;
alter table public.events            enable row level security;
alter table public.chores            enable row level security;
alter table public.chore_completions enable row level security;
alter table public.lists             enable row level security;
alter table public.list_items        enable row level security;
alter table public.display_tokens    enable row level security;

-- households: members read; anyone may create one they own; admins maintain it.
drop policy if exists "household read"   on public.households;
create policy "household read" on public.households
  for select using (public.is_household_member(id) or created_by = auth.uid());

drop policy if exists "household create" on public.households;
create policy "household create" on public.households
  for insert to authenticated with check (created_by = auth.uid());

drop policy if exists "household admin"  on public.households;
create policy "household admin" on public.households
  for update using (public.is_household_admin(id))
  with check (public.is_household_admin(id));

drop policy if exists "household delete" on public.households;
create policy "household delete" on public.households
  for delete using (public.is_household_admin(id));

-- members: everyone in the household sees the roster; admins change it.
drop policy if exists "members read"  on public.household_members;
create policy "members read" on public.household_members
  for select using (public.is_household_member(household_id)
                    or public.is_household_admin(household_id));

drop policy if exists "members write" on public.household_members;
create policy "members write" on public.household_members
  for all using (public.is_household_admin(household_id))
  with check (public.is_household_admin(household_id));

-- Shared household content: any member, full access. A family calendar where
-- people can't edit each other's entries is a family calendar nobody uses.
drop policy if exists "household events" on public.events;
create policy "household events" on public.events
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

drop policy if exists "household chores" on public.chores;
create policy "household chores" on public.chores
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

drop policy if exists "household chore completions" on public.chore_completions;
create policy "household chore completions" on public.chore_completions
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

drop policy if exists "household lists" on public.lists;
create policy "household lists" on public.lists
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

drop policy if exists "household list items" on public.list_items;
create policy "household list items" on public.list_items
  for all using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

-- Display tokens are an admin concern. Note there is no select policy for the
-- token itself beyond admins — the display authenticates through the RPC, not
-- by reading this table.
drop policy if exists "household display tokens" on public.display_tokens;
create policy "household display tokens" on public.display_tokens
  for all using (public.is_household_admin(household_id))
  with check (public.is_household_admin(household_id));

-- ============================================================================
-- DONE.
--
-- Bootstrap your household. NOTE: auth.uid() is null in the SQL editor unless
-- you impersonate a user, and a household with created_by = null can't be
-- administered by anyone — so look your id up and paste it literally:
--
--   select id, email from auth.users;          -- copy your id
--
--   insert into public.households (name, created_by)
--   values ('Smith', '<your-user-id>')
--   returning id;
--
--   insert into public.household_members (household_id, user_id, display_name, role, color)
--   values ('<that household id>', '<your-user-id>', 'Jeff', 'admin', '#4f7cff');
--
-- Add the rest of the family now if you like; leave user_id null until they
-- actually have logins:
--
--   insert into public.household_members (household_id, display_name, role, color)
--   values ('<household id>', 'Emma', 'kid', '#e8734a');
--
-- Verify — you should see your household, and exactly one member:
--
--   select h.name, m.display_name, m.role
--   from public.households h
--   join public.household_members m on m.household_id = h.id;
--
-- Confirm the boundary holds. This must return zero rows, because runs are
-- personal and were never household-scoped:
--
--   select column_name from information_schema.columns
--   where table_schema = 'public' and table_name in
--     ('runs','labs','lab_results','vitals','medical_visits','hsa_settings')
--     and column_name = 'household_id';
-- ============================================================================
