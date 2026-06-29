-- ============================================================================
-- Nutrition / calorie tracker — schema + RLS (per-user / individual use)
-- Run in: Supabase Dashboard → SQL Editor → New query → paste → Run
-- ============================================================================
--
-- Part of the personal-health-database pivot: this app is moving from a team XC
-- tool to an individual health DB (running + nutrition), so these tables are
-- scoped to the individual auth user via auth.uid() — NOT to the athlete/coach
-- roster used by the running tables. Family members get their own accounts
-- later; each sees only their own rows.
--
-- Design mirrors the existing running schema: uuid PKs (gen_random_uuid),
-- snake_case, timestamptz default now(). The shared "spine" (user_id,
-- occurred_at, source) is what lets nutrition and running join by day later.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Per-user settings (daily calorie goal). One row per user.
create table nutrition_settings (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  calorie_target integer check (calorie_target is null or calorie_target > 0),
  updated_at     timestamptz not null default now()
);

-- Reusable food definitions: saved recipes, scanned labels, barcode products.
-- Per-100g is the universal convention (a logged portion scales from it).
create table foods (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  name           text not null,
  kind           text not null check (kind in ('recipe','packaged','basic')),
  cal_100g       numeric(8,2),
  protein_100g   numeric(7,2),
  fat_100g       numeric(7,2),
  carbs_100g     numeric(7,2),
  fiber_100g     numeric(7,2),
  barcode        text,
  serving_size   text,
  final_weight_g numeric(9,2),          -- recipes: finished dish weight
  servings       numeric(6,2),          -- recipes: portions the recipe makes
  ingredients    jsonb,                 -- recipes: [{name,qty,unit,grams,...}]
  created_at     timestamptz not null default now()
);

-- Saved "usuals" — multi-item meals kept for one-tap re-logging.
-- Items stored as jsonb (the meal is re-logged as-is, no per-100g scaling).
create table nutrition_usuals (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  name           text not null,
  total_calories integer not null default 0,
  protein        numeric(7,2),
  fat            numeric(7,2),
  carbs          numeric(7,2),
  fiber          numeric(7,2),
  items          jsonb not null default '[]'::jsonb,
  created_at     timestamptz not null default now()
);

-- One logged consumption event (a meal, a labelled item, a recipe portion…).
create table nutrition_entries (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  occurred_at    timestamptz not null default now(),
  log_date       date not null,         -- local calendar day (set by the app)
  meal_type      text check (meal_type in ('breakfast','lunch','dinner','snack')),
  source         text not null check (source in
                   ('meal_parse','label','recipe','manual','barcode','usual')),
  title          text,
  original_text  text,
  total_calories integer not null default 0,
  protein        numeric(7,2),
  fat            numeric(7,2),
  carbs          numeric(7,2),
  fiber          numeric(7,2),
  created_at     timestamptz not null default now()
);

-- Line items within an entry.
create table nutrition_entry_items (
  id        uuid primary key default gen_random_uuid(),
  entry_id  uuid not null references nutrition_entries(id) on delete cascade,
  food_id   uuid references foods(id) on delete set null,
  position  smallint not null default 0,
  name      text not null,
  qty       numeric(9,2),
  unit      text,
  calories  integer not null default 0,
  protein   numeric(7,2),
  fat       numeric(7,2),
  carbs     numeric(7,2),
  fiber     numeric(7,2)
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

create index nutrition_entries_user_day_idx on nutrition_entries (user_id, log_date desc);
create index nutrition_entry_items_entry_idx on nutrition_entry_items (entry_id, position);
create index foods_user_kind_idx on foods (user_id, kind);
create index foods_user_barcode_idx on foods (user_id, barcode) where barcode is not null;
create index nutrition_usuals_user_idx on nutrition_usuals (user_id);

-- ---------------------------------------------------------------------------
-- Row Level Security — every table scoped to the individual auth user.
-- ---------------------------------------------------------------------------

alter table nutrition_settings    enable row level security;
alter table foods                 enable row level security;
alter table nutrition_usuals      enable row level security;
alter table nutrition_entries     enable row level security;
alter table nutrition_entry_items enable row level security;

-- Owner-only access keyed on auth.uid(). One "for all" policy per table.
create policy "own settings" on nutrition_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own foods" on foods
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own usuals" on nutrition_usuals
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own entries" on nutrition_entries
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Entry items inherit ownership from their parent entry.
create policy "own entry items" on nutrition_entry_items
  for all
  using (entry_id in (select id from nutrition_entries where user_id = auth.uid()))
  with check (entry_id in (select id from nutrition_entries where user_id = auth.uid()));

-- ============================================================================
-- DONE. Verify:
--   select tablename from pg_tables where tablename like 'nutrition%' or tablename = 'foods';
-- The Anthropic key for the ai-parse edge function is set separately:
--   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...   (see supabase/functions/ai-parse)
-- ============================================================================
