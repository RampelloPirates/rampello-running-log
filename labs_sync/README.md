# Lab results importer

Parses a downloaded lab-results PDF into structured markers and loads them into
Supabase, where `labs.html` shows them grouped by category with a "where you fall
in range" gauge and trends over time.

**Two formats, auto-detected** — just point it at any lab PDF:
- **Quest / Health Gorilla** (what Function Health exports): one report, one
  collection date, ~100+ markers.
- **BayCare / MyChart patient portal**: the "latest value per test" export, where
  each marker carries its own date. The importer splits it into **one report per
  distinct date** (so older draws become their own dated reports and feed trends).
  Portal short names (`WBC`, `HGB`, `LDL Calc`) are mapped to the Quest names
  (`WHITE BLOOD CELL COUNT`, …) and units normalised (`th/uL`→`Thousand/uL`) so the
  same marker trends as one continuous line across both sources.

From a **portal** PDF it also pulls **vitals** — blood pressure, weight, pulse,
temperature, height — into the `vitals` table (run `sql/18_vitals.sql` once), which
`vitals.html` charts over time. Each vital carries its own date, same as the labs.

Unlike the Strava sync, this is **run by hand** when you download a new report —
there's no API to poll, you just save the PDF and run the script.

## One-time setup

**1. Run the schema** — `sql/17_labs.sql` in the Supabase SQL Editor (adds
`lab_reports` + `lab_results`, per-user RLS).

**2. Install deps:**

```bash
pip install -r labs_sync/requirements.txt
```

## Importing a report

Set the same app credentials the Strava sync uses (your app sign-in), then point
the script at the PDF:

```bash
export SUPABASE_URL=https://dprmpgjgjppvdlyxlubr.supabase.co
export SUPABASE_ANON_KEY=...      # anon key from auth.js
export APP_EMAIL=...              # your app sign-in email
export APP_PASSWORD=...

python labs_sync/import_labs.py "path/to/Lab Results of Record.pdf"
```

On Windows PowerShell, set vars with `$env:APP_EMAIL="..."` etc.

Flags:
- `--dry-run` — parse and print the markers as JSON; **writes nothing**. Always
  worth doing first on a new report format to eyeball the extraction.
- `--replace` — re-import a report you've already loaded (deletes the old copy
  first). Without it, an already-imported report is skipped. For a portal PDF this
  applies per-date, so already-loaded dates are skipped and only new ones import.

## Notes

- **Dedup:** each report is keyed on `import_ref` — `quest:<accession>` for a Quest
  PDF, `portal:<date>` for each date in a portal PDF — so re-running is a no-op.
- **Reference ranges** are split into `low` / `high` / operator (`range`, `lte`,
  `gte`, …) so the app can draw the gauge. A couple of markers whose range wraps
  onto a second line in the PDF (LDL-C, Insulin) use curated fallback ranges —
  see `KNOWN_REF` in `import_labs.py`.
- **Other labs / older bloodwork:** the two built-in parsers cover Quest and the
  BayCare portal. For one-off historical values from other labs, enter them by hand
  in `labs.html` (create a report for that date, add markers).
- **Vitals** (blood pressure, weight, height) in a portal export are intentionally
  skipped — Labs is bloodwork only.
- **Categories** (Lipids, CBC, Thyroid, …) are derived from the marker name; tweak
  `CATEGORY_RULES` if something lands in the wrong group.
```
