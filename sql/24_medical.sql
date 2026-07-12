-- ============================================================================
-- Medical — doctor visits + HSA expense documentation.
--
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Two halves of one idea. A visit is what happened; an expense is what it cost
-- and whether you can still claim it. They're separate tables because they have
-- different lifecycles — an expense stays open for years after the visit is
-- ancient history — but an expense can point at the visit that caused it.
--
-- THE PHOTO IS THE ASSET. For the HSA half especially: extracted text is
-- convenient, but the image is what substantiates the claim if anyone ever
-- asks. Hence the storage bucket at the bottom — this is the one module where
-- losing the original would defeat the purpose.
-- ============================================================================

-- ── Who ────────────────────────────────────────────────────────────────────
-- Deliberately a plain text field rather than a household-members table. A
-- spouse's and dependents' medical expenses ARE HSA-qualified, so leaving them
-- out would understate the reimbursable balance — but a whole people/relations
-- model is more machinery than a household of a few names needs. The app offers
-- previously-used names as suggestions.

-- ── Visits ─────────────────────────────────────────────────────────────────
create table if not exists public.medical_visits (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  person         text not null default 'Me',
  visit_date     date not null,
  visit_type     text,          -- physical | sick | specialist | follow_up | urgent_care |
                                -- er | dental | vision | imaging | labs | therapy |
                                -- mental_health | procedure | vaccination | telehealth | other
  provider       text,          -- the doctor seen
  specialty      text,
  facility       text,          -- practice / hospital
  reason         text,          -- why you went
  diagnosis      text,
  treatment      text,
  instructions   text,          -- the care plan, in their words
  referrals      text,
  follow_up_on   date,          -- "recheck in 6 months" — the most-forgotten line on any summary
  follow_up_note text,
  notes          text,
  image_path     text,          -- the visit summary itself, in storage
  created_at     timestamptz not null default now()
);

create index if not exists medical_visits_user_date_idx
  on public.medical_visits (user_id, visit_date desc);
-- "What's coming up?" — cheap because follow-ups are rare.
create index if not exists medical_visits_followup_idx
  on public.medical_visits (user_id, follow_up_on) where follow_up_on is not null;

-- ── HSA settings ───────────────────────────────────────────────────────────
-- established_on is not trivia: an expense incurred BEFORE the HSA existed can
-- never be reimbursed from it. Storing the date lets the app flag a receipt
-- that's worthless before you file it away for eight years.
create table if not exists public.hsa_settings (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  established_on date,
  mileage_rate   numeric(5,3) not null default 0.21,   -- $/mile, IRS medical rate
  updated_at     timestamptz not null default now()
);

-- ── Expenses ───────────────────────────────────────────────────────────────
create table if not exists public.medical_expenses (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  person        text not null default 'Me',
  visit_id      uuid references public.medical_visits(id) on delete set null,
  service_date  date not null,                  -- when the care happened, NOT when you paid
  provider      text,
  category      text,                           -- office_visit | prescription | dental | vision |
                                                -- lab | imaging | procedure | otc | mileage | other
  -- billed vs paid are different numbers and only ONE of them is reimbursable.
  -- A bill is not proof of payment; what you actually paid out of pocket is.
  billed_amount numeric(10,2),
  paid_amount   numeric(10,2),
  miles         numeric(6,1),                   -- for category 'mileage'
  doc_kind      text,                           -- receipt | eob | bill | statement
  -- The double-dip guards. After eight years of receipts you will not remember,
  -- and getting this wrong is the one failure mode that actually costs money.
  reimbursed     boolean not null default false,
  reimbursed_on  date,
  tax_deducted   boolean not null default false,  -- claimed as an itemized deduction: can't also reimburse
  note          text,
  image_path    text,                           -- the receipt/EOB itself, in storage
  created_at    timestamptz not null default now()
);

create index if not exists medical_expenses_user_date_idx
  on public.medical_expenses (user_id, service_date desc);
-- The headline number: what you could still withdraw, tax-free, today.
create index if not exists medical_expenses_claimable_idx
  on public.medical_expenses (user_id) where not reimbursed and not tax_deducted;

-- ── Prescriptions ride in the supplements checklist ────────────────────────
-- A prescription IS a thing you take daily, so it belongs in the checklist you
-- already open every morning rather than a second list you'd forget. But a
-- 10-day antibiotic must not sit there forever — `ends_on` lets it fall off by
-- itself. Existing supplement rows are unaffected: everything here is nullable.
alter table public.supplements
  add column if not exists kind          text not null default 'supplement',  -- supplement | prescription
  add column if not exists prescribed_on date,
  add column if not exists ends_on       date,
  add column if not exists prescriber    text,
  add column if not exists visit_id      uuid references public.medical_visits(id) on delete set null;

-- ── RLS ────────────────────────────────────────────────────────────────────
alter table public.medical_visits   enable row level security;
alter table public.medical_expenses enable row level security;
alter table public.hsa_settings     enable row level security;

drop policy if exists "own visits" on public.medical_visits;
create policy "own visits" on public.medical_visits
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own expenses" on public.medical_expenses;
create policy "own expenses" on public.medical_expenses
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own hsa settings" on public.hsa_settings;
create policy "own hsa settings" on public.hsa_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── Storage: the originals ─────────────────────────────────────────────────
-- Private bucket. Files are keyed <user_id>/<uuid>.jpg, and the policies below
-- only let you touch a path whose first folder is your own user id — so nobody
-- can read anyone else's receipts even with a valid login.
insert into storage.buckets (id, name, public)
values ('medical', 'medical', false)
on conflict (id) do nothing;

drop policy if exists "own medical files read"   on storage.objects;
drop policy if exists "own medical files write"  on storage.objects;
drop policy if exists "own medical files delete" on storage.objects;

create policy "own medical files read" on storage.objects
  for select using (
    bucket_id = 'medical' and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "own medical files write" on storage.objects
  for insert with check (
    bucket_id = 'medical' and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "own medical files delete" on storage.objects
  for delete using (
    bucket_id = 'medical' and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ============================================================================
-- DONE. Verify:
--   select count(*) from public.medical_visits;
--   select coalesce(sum(paid_amount),0) as claimable
--     from public.medical_expenses where not reimbursed and not tax_deducted;
--   select id, public from storage.buckets where id = 'medical';
-- ============================================================================
