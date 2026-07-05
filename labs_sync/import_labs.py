#!/usr/bin/env python3
"""
Quest / Health Gorilla lab PDF -> Supabase importer.

Parses a downloaded lab-results PDF (the kind Function Health / Quest export via
Health Gorilla) into structured markers — value, unit, and the reference range
split into low/high/operator so the app can draw a "where you fall in range"
gauge — and upserts them into `lab_reports` + `lab_results`.

Usage:
  pip install -r labs_sync/requirements.txt
  # set the same app creds strava_sync uses (or export inline):
  export SUPABASE_URL=... SUPABASE_ANON_KEY=... APP_EMAIL=... APP_PASSWORD=...
  python labs_sync/import_labs.py "path/to/Lab Results of Record.pdf"
  python labs_sync/import_labs.py --dry-run "path/to/file.pdf"    # parse only, no DB
  python labs_sync/import_labs.py --replace "path/to/file.pdf"    # re-import same report

Dedup: each report imports once, keyed on the lab's accession number
(import_ref = 'quest:<accession>'). Re-run is a no-op unless --replace.
"""
import os
import re
import sys
import json

import pypdf

# ── recognised qualitative results ──────────────────────────────────────────
QUALITATIVE = {
    "NEGATIVE", "POSITIVE", "YELLOW", "CLEAR", "CLOUDY", "HAZY", "TRACE",
    "NONE SEEN", "NOT SEEN", "NON-REACTIVE", "NONREACTIVE", "REACTIVE",
    "DETECTED", "NOT DETECTED",
}

BOILERPLATE_SUBSTR = [
    "Printed from", "Health Gorilla", "healthgorilla", "intended only for",
    "intended recipient", "dissemination", "privacy@", "contain information",
    "obtained this document", "PATIENT INFORMATION", "Phone (H)", "Patient ID",
    "ORDERING PHYSICIAN", "Congress Avenue", "Floor 14", "Austin, TX",
    "Quest Result", "Test In Range Out", "Time Reported", "Collection Date",
    "Accession", "Lab Ref", "STATUS", "Source: Quest", "Gender: Male",
    "DOB:", "Number:",
]

# marker-name keyword -> display category (grouping in the UI)
CATEGORY_RULES = [
    ("Lipids", ["CHOLESTEROL", "HDL", "LDL", "TRIGLYCERIDE", "APOLIPOPROTEIN", "LIPOPROTEIN", "CHOL/"]),
    ("Fatty acids", ["OMEGA", "EPA", "DHA", "DPA", "ARACHIDONIC", "LINOLEIC"]),
    ("CBC", ["WHITE BLOOD", "RED BLOOD", "HEMOGLOBIN A1C", "HEMOGLOBIN", "HEMATOCRIT", "MCV",
             "MCH", "MCHC", "RDW", "PLATELET", "MPV", "NEUTROPHIL", "LYMPHOCYTE", "MONOCYTE",
             "EOSINOPHIL", "BASOPHIL"]),
    ("Thyroid", ["TSH", "T4", "T3", "THYROGLOBULIN", "THYROID PEROX"]),
    ("Hormones", ["DHEA", "FSH", "LH", "PROLACTIN", "ESTRADIOL", "TESTOSTERONE", "INSULIN",
                  "CORTISOL", "SEX HORMONE", "PSA", "LEPTIN"]),
    ("Vitamins & minerals", ["VITAMIN", "IRON", "FERRITIN", "BINDING CAPACITY", "SATURATION",
                             "MAGNESIUM", "ZINC", "METHYLMALONIC", "HOMOCYSTEINE", "URIC ACID"]),
    ("Inflammation", ["CRP", "RHEUMATOID", "ANA "]),
    ("Heavy metals", ["MERCURY", "LEAD"]),
    ("Urinalysis", ["COLOR", "APPEARANCE", "SPECIFIC GRAVITY", "KETONE", "NITRITE",
                    "LEUKOCYTE ESTERASE", "OCCULT", "HYALINE", "SQUAMOUS", "BACTERIA", "URINE"]),
    ("Metabolic", ["GLUCOSE", "UREA", "BUN", "CREATININE", "EGFR", "SODIUM", "POTASSIUM",
                   "CHLORIDE", "CARBON DIOXIDE", "CALCIUM", "PROTEIN", "ALBUMIN", "GLOBULIN",
                   "BILIRUBIN", "ALKALINE", "AST", "ALT", "GGT", "AMYLASE", "LIPASE", "A1C", "PH"]),
]

# A few markers whose reference range wraps onto a following line in the PDF and
# so can't be parsed inline. Curated fallbacks (Quest standard adult ranges).
KNOWN_REF = {
    "LDL-CHOLESTEROL": {"ref_operator": "lte", "ref_high": 100.0},
    "INSULIN":         {"ref_operator": "lte", "ref_high": 18.4},
}

PANEL_RE = re.compile(r"^(?P<panel>[A-Z][A-Z0-9 ,()/%'.\-]+?)\s+Collected:")
VAL = (r"(?:[<>]\s?=?\s?\d[\d.]*|\d[\d.]*|"
       + "|".join(sorted(QUALITATIVE, key=len, reverse=True)).replace(" ", r"\ ") + r")")
RESULT_RE = re.compile(
    r"^(?P<name>[A-Z%][A-Za-z0-9 ,()/%'.\-]*?)\s+"
    r"(?P<val>" + VAL + r")"
    r"(?:\s+(?P<flag>[HL]))?"
    r"(?:\s+(?P<rest>.*?))?$")


def categorize(name):
    u = name.upper()
    for cat, kws in CATEGORY_RULES:
        if any(k in u for k in kws):
            return cat
    return "Other"


def clean_lines(reader):
    out = []
    for p in reader.pages:
        for ln in (p.extract_text() or "").split("\n"):
            s = re.sub(r"\s+", " ", ln.replace("�", " ").strip())
            if not s:
                continue
            if s in ("UTC", "Jeffrey Smith") or s.startswith(("Page ",)):
                continue
            if s.startswith("Jeffrey Smith Quest") or re.fullmatch(r"[A-Z]{2}\d{6,}[A-Z]?", s):
                continue
            # keep panel headers (carry 'Collected:') even if they also say 'Received:'
            if "Collected:" not in s and ("Received:" in s or any(b in s for b in BOILERPLATE_SUBSTR)):
                continue
            out.append(s)
    return out


def merge_wraps(lines):
    merged = []
    for s in lines:
        if merged and re.fullmatch(r"/[A-Za-z0-9]+", s):
            merged[-1] += s
            continue
        if (merged and re.fullmatch(r"[A-Z]{2,4}", s) and re.search(r"\d", merged[-1])
                and "Collected:" not in merged[-1]):
            merged[-1] += " " + s
            continue
        merged.append(s)
    return merged


def is_marker_name(name):
    alpha = re.sub(r"[^A-Za-z]", "", name.replace("A1c", "A1C"))
    return bool(alpha) and alpha.isupper()


def parse_ref(raw, value_is_text):
    s = re.sub(r"\(calc\)", " ", raw)
    s = re.sub(r"\s+(Z4M|[A-Z]{2,4})$", "", s).strip().rstrip(" .")
    if value_is_text:
        return {"ref_operator": "qual", "ref_low": None, "ref_high": None,
                "unit": None, "normal_text": s.strip() or None}
    n = re.sub(r"(?i)\bor\b", " ", s)
    n = re.sub(r"\s*=\s*", "=", n)
    n = re.sub(r"\s+", " ", n).strip()
    m = re.match(r"^(?P<op><=|>=|<|>)?\s*(?P<a>\d[\d.]*)(?:\s*-\s*(?P<b>\d[\d.]*))?\s*(?P<unit>.*)$", n)
    if not m:
        unit = re.sub(r"^See Note:?\s*", "", s).strip() or None
        return {"ref_operator": "none", "ref_low": None, "ref_high": None,
                "unit": unit, "normal_text": None}
    op, a, b = m.group("op"), float(m.group("a")), m.group("b")
    unit = (m.group("unit") or "").strip() or None
    if b is not None:
        return {"ref_operator": "range", "ref_low": a, "ref_high": float(b),
                "unit": unit, "normal_text": None}
    if op in ("<", "<="):
        return {"ref_operator": "lte", "ref_low": None, "ref_high": a, "unit": unit, "normal_text": None}
    if op in (">", ">="):
        return {"ref_operator": "gte", "ref_low": a, "ref_high": None, "unit": unit, "normal_text": None}
    return {"ref_operator": "eq", "ref_low": a, "ref_high": a, "unit": unit, "normal_text": None}


def parse_results(lines):
    rows, panel, order = [], None, 0
    for s in lines:
        if s.startswith("Appendix") or "Enhanced PDF Report" in s:
            break                                    # the report repeats itself in an appendix
        m = PANEL_RE.match(s)
        if m:
            panel = m.group("panel").strip()
            continue
        if "Collected:" in s or "Received:" in s:
            continue
        m = RESULT_RE.match(s)
        if not m:
            continue
        name = m.group("name").strip(" :,-")
        if not is_marker_name(name):
            continue
        raw_val = re.sub(r"\s+", "", m.group("val"))
        value_is_text = raw_val.upper() in {q.replace(" ", "") for q in QUALITATIVE}
        vnum, vtext = None, None
        if value_is_text:
            vtext = m.group("val").strip()
        elif raw_val[0] in "<>":
            vtext = raw_val
            mnum = re.search(r"[\d.]+", raw_val)
            vnum = float(mnum.group()) if mnum else None
        else:
            vnum = float(raw_val)
        ref = parse_ref((m.group("rest") or "").strip(), value_is_text)
        if ref["ref_operator"] in ("none", "eq") and name in KNOWN_REF:
            ref.update(KNOWN_REF[name])
        order += 1
        rows.append({
            "category": categorize(name), "panel": panel, "name": name,
            "value_num": vnum, "value_text": vtext, "flag": m.group("flag"),
            "unit": ref["unit"], "ref_operator": ref["ref_operator"],
            "ref_low": ref["ref_low"], "ref_high": ref["ref_high"],
            "normal_text": ref["normal_text"], "sort_order": order,
        })
    return rows


def parse_report_meta(reader):
    """Pull collection date, accession, source, physician, fasting from page 1."""
    t = reader.pages[0].extract_text() or ""
    flat = re.sub(r"\s+", " ", t)

    def find(pat):
        m = re.search(pat, flat)
        return m.group(1).strip() if m else None

    coll = find(r"Collection Date:\s*(\d{2}/\d{2}/\d{4})")
    collected_on = None
    if coll:
        mm, dd, yy = coll.split("/")
        collected_on = f"{yy}-{mm}-{dd}"
    accession = find(r"Accession Number:\s*([A-Z0-9]+)") or find(r"\b([A-Z]{2}\d{6,}[A-Z])\b")
    physician = find(r"ORDERING PHYSICIAN:\s*(.+?)\s+\d{2,3}\s") or find(r"ORDERING PHYSICIAN:\s*([A-Za-z .,]+?D\.?O\.?)")
    source = "Quest" if "Quest" in flat else find(r"Source:\s*(\w+)")
    fasting = True if re.search(r"FASTING:\s*YES", flat) else (False if re.search(r"FASTING:\s*NO", flat) else None)
    return {
        "collected_on": collected_on,
        "source": source,
        "physician": physician,
        "fasting": fasting,
        "import_ref": f"quest:{accession}" if accession else None,
    }


def parse_pdf(path):
    reader = pypdf.PdfReader(path)
    meta = parse_report_meta(reader)
    rows = parse_results(merge_wraps(clean_lines(reader)))
    return meta, rows


# ── DB upsert ────────────────────────────────────────────────────────────────
def env(key, required=False, default=None):
    v = os.environ.get(key, default)
    if required and not v:
        sys.exit(f"Missing required env var: {key}")
    return v


def upload(meta, rows, replace=False):
    from supabase import create_client
    url = env("SUPABASE_URL", True)
    key = env("SUPABASE_ANON_KEY", True)
    email = env("APP_EMAIL", True)
    password = env("APP_PASSWORD", True)

    sb = create_client(url, key)
    auth = sb.auth.sign_in_with_password({"email": email, "password": password})
    sb.postgrest.auth(auth.session.access_token)
    user_id = auth.user.id

    if not meta.get("collected_on"):
        sys.exit("Could not read a collection date from the PDF — aborting.")
    ref = meta.get("import_ref") or f"quest:{meta['collected_on']}"

    existing = sb.table("lab_reports").select("id").eq("user_id", user_id).eq("import_ref", ref).execute()
    if existing.data:
        if not replace:
            print(f"Report {ref} already imported ({len(existing.data)} found). "
                  f"Use --replace to overwrite. Nothing to do.")
            return
        for r in existing.data:
            sb.table("lab_reports").delete().eq("id", r["id"]).execute()   # cascades to results
        print(f"Replacing existing report {ref}.")

    rep = sb.table("lab_reports").insert({
        "user_id": user_id,
        "collected_on": meta["collected_on"],
        "source": meta.get("source"),
        "physician": meta.get("physician"),
        "fasting": meta.get("fasting"),
        "import_ref": ref,
    }).execute()
    report_id = rep.data[0]["id"]

    payload = [{**r, "user_id": user_id, "report_id": report_id} for r in rows]
    sb.table("lab_results").insert(payload).execute()
    print(f"Imported {len(payload)} markers for {meta['collected_on']} ({meta.get('source')}).")


def main():
    args = sys.argv[1:]
    dry = "--dry-run" in args
    replace = "--replace" in args
    paths = [a for a in args if not a.startswith("--")]
    if not paths:
        sys.exit("Usage: python labs_sync/import_labs.py [--dry-run] [--replace] <lab.pdf>")

    meta, rows = parse_pdf(paths[0])
    print(f"Report: {meta.get('collected_on')}  source={meta.get('source')}  "
          f"ref={meta.get('import_ref')}  fasting={meta.get('fasting')}")
    print(f"Parsed {len(rows)} markers.")
    if dry:
        print(json.dumps({"meta": meta, "results": rows}, indent=1, default=str))
        return
    upload(meta, rows, replace=replace)


if __name__ == "__main__":
    main()
