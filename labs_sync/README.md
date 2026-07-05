# Lab results importer

Parses a downloaded **Quest / Health Gorilla** lab PDF (the kind Function Health
exports) into structured markers and loads them into Supabase, where `labs.html`
shows them grouped by category with a "where you fall in range" gauge and trends
over time.

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
  first). Without it, an already-imported report is skipped.

## Notes

- **Dedup:** each report is keyed on the lab's accession number
  (`import_ref = quest:<accession>`), so re-running is a no-op.
- **Reference ranges** are split into `low` / `high` / operator (`range`, `lte`,
  `gte`, …) so the app can draw the gauge. A couple of markers whose range wraps
  onto a second line in the PDF (LDL-C, Insulin) use curated fallback ranges —
  see `KNOWN_REF` in `import_labs.py`.
- **Other labs / older bloodwork:** this parser targets the Quest/Health-Gorilla
  layout. For one-off historical values from other labs, enter them by hand in
  `labs.html` (create a report for that date, add markers).
- **Categories** (Lipids, CBC, Thyroid, …) are derived from the marker name; tweak
  `CATEGORY_RULES` if something lands in the wrong group.
```
