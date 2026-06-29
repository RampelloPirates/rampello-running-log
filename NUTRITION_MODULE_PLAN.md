# Nutrition Module — Build Plan

Context handoff from a planning chat. This module adds calorie + macro tracking to the
Rampello personal health database (the project formerly scoped as the "running log").
Goal: nutrition becomes one domain alongside running, sharing a common spine so the two
can be joined by day later.

A working prototype already exists as a React artifact (`calorie-tracker.jsx`) — it is the
**reference implementation** for behavior, the parsing prompts, and the macro/fiber math.
Drop that file in the repo for reference. This plan ports it onto Supabase + Vercel.

## Current status — THIS IS A PORT, NOT A GREENFIELD BUILD

The app is already built and works on desktop. Do not rebuild it from scratch.
- The full UI + logic lives in `calorie-tracker.jsx` (single-file React artifact).
- It is a single file by necessity (artifact constraint); restructure it into Rampello's
  normal component/file layout. The *logic* ports directly; the *file organization* does not.
- Only two integration points change: (1) `window.storage` → Supabase, (2) the direct
  `api.anthropic.com` fetch → the `ai-parse` edge function. Everything else is reuse.
- If `calorie-tracker.jsx` is NOT present in the repo, the prompts + scaling math below are
  a complete-enough fallback to reproduce the behavior — but prefer porting the actual file.

---

## Why server-side (don't skip this)

The prototype calls the Anthropic API directly from the browser. That works in a desktop
artifact but is **blocked by CORS on iOS**, and a client should never hold the API key
anyway. So the model call moves into a Supabase Edge Function. This also unlocks the
barcode → Open Food Facts lookup, which the browser couldn't do.

---

## STEP 0 — Discover existing Rampello conventions first

Before writing anything, inspect the current project so the nutrition module mirrors it
rather than clashing. Determine and then match:

- Table naming + key style: `uuid` vs `bigint`, snake_case, timestamp conventions.
- Whether RLS is enabled and the existing policy pattern.
- How the Vercel front-end talks to Supabase: anon key + client calls, or via functions.
- Existing `user_id` / auth shape (Supabase Auth? single-user?).
- Where existing tables live (public schema? prefixed?).

Mirror all of the above. The shapes below are intent, not literal DDL — adapt to match.

---

## Shared spine (every health-domain table)

`user_id`, `occurred_at` (timestamptz), `source` (text). This is what lets nutrition and
running join by day without coupling. A daily-rollup view on top feeds a future dashboard.

---

## Tables (namespace with `nutrition_` prefix or a separate schema)

**`foods`** — reusable food definitions. A saved recipe, a scanned label, and an Open Food
Facts product are all just rows here. Per-100g is the universal convention.
- name, kind (`recipe` | `packaged` | `basic`)
- per_100g: calories, protein, fat, carbs, fiber
- optional: barcode, serving_size, final_weight_g (recipes), ingredients (jsonb, recipes)
- user_id, created_at

**`nutrition_entries`** — one logged consumption event.
- occurred_at, meal_type (nullable), source (`meal_parse` | `label` | `recipe` | `manual` | `barcode`)
- original_text (nullable), total_calories, protein, fat, carbs, fiber
- user_id

**`nutrition_entry_items`** — line items within an entry.
- entry_id (fk), food_id (fk, nullable)
- name, qty, unit, calories, protein, fat, carbs, fiber

Day total = sum of entries' totals for a date. Macro totals likewise. (In the prototype,
older entries lacked macros and fell back to summing item-level macros — keep that
fallback in any importer.)

---

## Edge Function — `ai-parse` (single function, `mode` param)

Same pattern as the existing DocuSeal edge function: Deno `serve`, CORS headers, read JSON
body, call external API with a secret key, return JSON. Anthropic key in Supabase secrets
(NOT in client). `mode` ∈ `meal` | `label` | `recipe`. Model: `claude-sonnet-4-6`.
Strip ```json fences before parsing the model's text. Return the parsed object.

A separate (or same-function) path handles **barcode**: fetch
`https://world.openfoodfacts.org/api/v2/product/{barcode}.json` server-side, map
energy-kcal_100g + nutriments to the `foods` per-100g shape, upsert, return it.

### Prompts (lifted from the prototype)

**meal** — input: free text. Output ONLY JSON:
```
{"items":[{"name","qty","unit","calories","protein","fat","carbs","fiber"}],"note":""}
```
Each item's macros/calories are totals for that quantity. Assume one serving if unstated.

**label** — input: base64 image of a Nutrition Facts panel. Output ONLY JSON:
```
{"productName","servingSize","caloriesPerServing","servingsPerContainer",
 "proteinPerServing","fatPerServing","carbsPerServing","fiberPerServing"}
```
null for anything unreadable. Front-end multiplies by servings eaten.

**recipe** — input: ingredient list text. Output ONLY JSON:
```
{"ingredients":[{"name","qty","unit","grams","calories","protein","fat","carbs","fiber"}],"note":""}
```
grams = estimated weight of that quantity; nutrients are totals for that quantity.
Per-100g = total nutrient / finished_weight * 100. Finished weight defaults to the raw
gram sum but should be user-overridable (cooking changes weight; calories are conserved).

---

## Scaling math (from prototype — preserve exactly)

`round1(n) = Math.round(n * 10) / 10` (one decimal). Calories round to integer.

**Meal items.** On parse, store per-unit ratios for each item:
`calPerUnit = calories/qty`, and likewise `pPerUnit, fPerUnit, cPerUnit, fibPerUnit`.
- Editing **qty** rescales everything: `calories = round(calPerUnit*qty)`,
  `protein = round1(pPerUnit*qty)`, etc.
- Editing **calories** directly only updates `calPerUnit = calories/qty` (macros unchanged).
- Strip the per-unit fields before persisting the item.

**Recipes.** Store per-gram ratios: `calPerG = calories/grams`, `pPerG, fPerG, cPerG, fibPerG`.
- Editing an ingredient's **grams** rescales its nutrients via the per-gram ratios.
- `finalWeight` defaults to the sum of ingredient grams, user-overridable.
- `per_100g.X = round(totalX / finalWeight * 100)` for cal + each macro.
- Logging a portion of N grams: `X = round1(per_100g.X * N / 100)`.

**Labels.** `total = caloriesPerServing * servingsEaten`; each macro
`= round1(macroPerServing * servingsEaten)`.

**Day totals.** Sum entry totals for the date. For macros, use the entry's stored macros,
falling back to summing item-level macros when an entry predates the macro fields.

---

## Front-end

Reuse the prototype's React. Two repoints:
1. `window.storage` → Supabase (the three tables above).
2. Direct `api.anthropic.com` fetch → `ai-parse` edge function.

Everything else (editable line items with qty-scaling, the macro/fiber strip, recipe
builder, usuals, history, daily totals) ports as-is. Deploy on Vercel like the rest of the
project.

---

## Accuracy note (carry forward)

Per-item macro estimates from text stack error across a meal. For production accuracy,
match parsed ingredients/foods against USDA FoodData Central rather than pure estimation —
labels, recipes, and barcode lookups are already exact and should be preferred over the
text-parse path when available.

---

## Open decisions

- Separate Supabase project vs. same project as running data (leaning: same project, own
  tables/schema — shared infra, clean data separation).
- Whether to seed `foods` from USDA now or grow it from what gets logged.
- Auth: single-user shortcut vs. full Supabase Auth (match whatever running already uses).
