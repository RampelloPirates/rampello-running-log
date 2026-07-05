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


# ── BayCare / MyChart patient-portal format ──────────────────────────────────
# A different layout entirely: results stacked vertically (name / value / Date: /
# Reference Range:), one *latest* value per marker, each from its own date. We map
# the portal's short names to the Quest names above so a marker trends as one line
# across both sources, and normalise unit spellings for the same reason.
PORTAL_NAME_MAP = {
    "WBC": "WHITE BLOOD CELL COUNT", "RBC": "RED BLOOD CELL COUNT", "HGB": "HEMOGLOBIN",
    "HCT": "HEMATOCRIT", "MCV": "MCV", "MCH": "MCH", "MCHC": "MCHC", "RDW": "RDW",
    "PLT": "PLATELET COUNT", "MPV": "MPV", "SEGS": "NEUTROPHILS", "LYMPHS": "LYMPHOCYTES",
    "MONO": "MONOCYTES", "EOS": "EOSINOPHILS", "BASO": "BASOPHILS",
    "NEUTROPHIL, ABS": "ABSOLUTE NEUTROPHILS", "LYMPH, ABS": "ABSOLUTE LYMPHOCYTES",
    "MONOCYTE, ABS": "ABSOLUTE MONOCYTES", "EOSINOPHIL, ABS": "ABSOLUTE EOSINOPHILS",
    "BASOPHIL, ABS": "ABSOLUTE BASOPHILS", "BUN": "UREA NITROGEN (BUN)",
    "BUN/CREAT": "BUN/CREATININE RATIO", "PROTEIN, TOT": "PROTEIN, TOTAL",
    "ALB/GLOB": "ALBUMIN/GLOBULIN RATIO", "BILI, TOTAL": "BILIRUBIN, TOTAL",
    "ALK PHOS": "ALKALINE PHOSPHATASE", "EGFR (CR)": "EGFR", "TRIGLYCERIDE": "TRIGLYCERIDES",
    "CHOLESTEROL": "CHOLESTEROL, TOTAL", "HDL": "HDL CHOLESTEROL", "LDL CALC": "LDL-CHOLESTEROL",
    "RISK RATIO": "CHOL/HDLC RATIO", "SP GRAV": "SPECIFIC GRAVITY", "KETONE": "KETONES",
    "BLOOD": "OCCULT BLOOD", "LEUK EST": "LEUKOCYTE ESTERASE",
}
PORTAL_UNIT_MAP = {"th/uL": "Thousand/uL", "mill/uL": "Million/uL", "IU/L": "U/L"}
PORTAL_QUAL = {"NEGATIVE", "POSITIVE", "YELLOW", "CLEAR", "CLOUDY", "TRACE", "NONE SEEN"}
PORTAL_SKIP_VALUE = {"SEE NOTE", "SEE BELOW", "N/A", "NEVER A SMOKER", "STANDING", "NO", "YES"}
PORTAL_SKIP_NAME = ["BLOOD PRESSURE", "WEIGHT", "HEIGHT", "TYPE OF SCALE", "TOBACCO",
                    "ECRCL", "AKI", "LIPID INTERP", "CULTURE REFLEXED",
                    "EGFR (NONAFRAM)", "EGFR (AFRAM)"]
PORTAL_SKIP_UNITS = {"kg", "lb", "lbs", "oz", "inch", "inch(es)", "mmhg"}
PORTAL_MONTHS = {m: i + 1 for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])}
PORTAL_DROP = {"Skip to Content", "Health Record", "Results", "All results",
               "Patient Viewable Results", "Hematology", "Urinalysis", "General Chem",
               "Lipids", "Health Profile", "Medications", "Procedures", "Documents",
               "Clinical Notes", "Radiology/Cardiology", "Pathology", "Microbiology",
               "Visit Summaries", "SBP/DBP"}
PORTAL_TIME_RE = re.compile(r"^(a\.m\.|p\.m\.)\s+E[SD]T$", re.I)
PORTAL_DATE_RE = re.compile(r"([A-Z][a-z]{2})\s*(\d{1,2}),?\s*(\d{4})")


def portal_clean(reader):
    out = []
    for p in reader.pages:
        for ln in (p.extract_text() or "").split("\n"):
            s = re.sub("[-]", "", ln).strip()   # strip portal graph-icon glyphs
            if not s or s.startswith("====="):
                continue
            if s.startswith("View all") or s.replace(" ", "") == "Viewallforthisresult":
                continue
            if s in PORTAL_DROP:
                continue
            if s.startswith(("The information provided", "If you believe", "Test results are released",
                             "days.", "Graphing is available", "on the result", "our Patient Portal",
                             "provider to request", "Vital signs", "record.", "surgery",
                             "Results are typically", "soon as they", "see results",
                             "data is incorrect", "equipment not", "BayCare", "document or image",
                             "contain information", "JEFFREY", "Jeffrey")):
                continue
            if s.startswith("Date:") and s != "Date:":
                continue
            if s.startswith("Range:") and s != "Range:":
                s = s[len("Range:"):].strip()
                if not s:
                    continue
            out.append(s)
    return out


def portal_date(line):
    m = PORTAL_DATE_RE.search(line)
    if not m:
        return None
    mon = PORTAL_MONTHS.get(m.group(1))
    return f"{int(m.group(3)):04d}-{mon:02d}-{int(m.group(2)):02d}" if mon else None


def portal_is_value(s):
    t = s.strip()
    if re.match(r"^[<>]?=?\s*\d", t):
        return True
    up = t.upper().rstrip(" .")
    return any(up.startswith(q) for q in PORTAL_QUAL) or any(up.startswith(k) for k in PORTAL_SKIP_VALUE)


def portal_value(s):
    """-> (value_num, value_text, unit, flag, skip)"""
    flag = None
    m = re.search(r"\((High|Low)\)", s, re.I)
    if m:
        flag = "H" if m.group(1).lower() == "high" else "L"
    s = re.sub(r"\((High|Low)\)", "", s, flags=re.I).strip()
    up = s.upper().rstrip(" .")
    if any(up.startswith(k) for k in PORTAL_SKIP_VALUE):
        return (None, None, None, None, True)
    for q in PORTAL_QUAL:
        if up.startswith(q):
            unit = s[len(q):].strip() or None
            return (None, q.title() if q != "NONE SEEN" else "None seen", unit, flag, False)
    m = re.match(r"^(?P<pre>[<>]=?)?\s*(?P<num>\d[\d.]*)\s*(?P<unit>.*)$", s)
    if not m:
        return (None, None, None, flag, True)
    unit = (m.group("unit") or "").strip() or None
    vtext = (m.group("pre") + m.group("num")) if m.group("pre") else None
    return (float(m.group("num")), vtext, unit, flag, False)


def portal_range(lines):
    raw = " ".join(lines).strip()
    if not raw:
        return {"ref_operator": "none", "ref_low": None, "ref_high": None, "unit": None, "normal_text": None}
    up = raw.upper()
    for q in PORTAL_QUAL:
        if up.startswith(q):
            return {"ref_operator": "qual", "ref_low": None, "ref_high": None, "unit": None, "normal_text": q.title()}
    m = re.match(r"^(?P<lo>[\d.]+)\s*(?P<u1>[^\d-]*?)\s*-\s*(?P<hi>[\d.]+)\s*(?P<u2>.*)$", raw)
    if m:
        unit = (m.group("u2") or m.group("u1") or "").strip() or None
        return {"ref_operator": "range", "ref_low": float(m.group("lo")), "ref_high": float(m.group("hi")),
                "unit": unit, "normal_text": None}
    m = re.match(r"^(?P<op>>=|<=|>|<)\s*(?P<n>[\d.]+)\s*(?P<u>.*)$", raw)
    if m:
        n, unit = float(m.group("n")), (m.group("u") or "").strip() or None
        if m.group("op") in (">=", ">"):
            return {"ref_operator": "gte", "ref_low": n, "ref_high": None, "unit": unit, "normal_text": None}
        return {"ref_operator": "lte", "ref_low": None, "ref_high": n, "unit": unit, "normal_text": None}
    return {"ref_operator": "none", "ref_low": None, "ref_high": None, "unit": None, "normal_text": None}


def norm_unit(u):
    return PORTAL_UNIT_MAP.get(u, u) if u else u


def parse_portal(reader):
    """Return groups: [(report_meta, rows), …] — one report per distinct date."""
    lines = portal_clean(reader)
    date_idx = [i for i, s in enumerate(lines) if s == "Date:"]
    by_date = {}
    for k, di in enumerate(date_idx):
        if di < 2:
            continue
        value_line, name = lines[di - 1], lines[di - 2]
        if portal_is_value(name) and di >= 3:      # glyph/reflow bumped the value onto its own line
            name = lines[di - 3]
        date = portal_date(lines[di + 1]) if di + 1 < len(lines) else None
        stop = date_idx[k + 1] - 2 if k + 1 < len(date_idx) else len(lines)
        seg = lines[di + 1:stop]
        rng_lines = []
        if "Range:" in seg:
            ri = seg.index("Range:")
            rng_lines = [x for x in seg[ri + 1:]
                         if not PORTAL_TIME_RE.match(x) and not PORTAL_DATE_RE.search(x)
                         and x not in ("Reference", "Range:")]
        nm_up = name.upper().strip()
        if any(sk in nm_up for sk in PORTAL_SKIP_NAME):
            continue
        vnum, vtext, vunit, flag, skip = portal_value(value_line)
        if skip or (vunit or "").lower().strip() in PORTAL_SKIP_UNITS or not date:
            continue
        ref = portal_range(rng_lines)
        canon = PORTAL_NAME_MAP.get(nm_up, name.strip())
        grp = by_date.setdefault(date, [])
        grp.append({
            "category": categorize(canon), "panel": None, "name": canon,
            "value_num": vnum, "value_text": vtext, "flag": flag,
            "unit": norm_unit(vunit or ref["unit"]), "ref_operator": ref["ref_operator"],
            "ref_low": ref["ref_low"], "ref_high": ref["ref_high"],
            "normal_text": ref["normal_text"], "sort_order": len(grp),
        })
    groups = []
    for date in sorted(by_date):
        groups.append(({"collected_on": date, "source": "BayCare (portal)",
                        "physician": None, "fasting": None,
                        "import_ref": f"portal:{date}"}, by_date[date]))
    return groups


def detect_format(reader):
    head = " ".join((reader.pages[i].extract_text() or "") for i in range(min(3, len(reader.pages))))
    if "View all for this result" in head or "BayCare" in head or "Patient Viewable Results" in head:
        return "portal"
    return "quest"


def parse_pdf(path):
    """Return (format, groups) where groups = [(report_meta, rows), …]."""
    reader = pypdf.PdfReader(path)
    fmt = detect_format(reader)
    if fmt == "portal":
        return fmt, parse_portal(reader)
    meta = parse_report_meta(reader)
    rows = parse_results(merge_wraps(clean_lines(reader)))
    return fmt, [(meta, rows)]


# ── DB upsert ────────────────────────────────────────────────────────────────
def env(key, required=False, default=None):
    v = os.environ.get(key, default)
    if required and not v:
        sys.exit(f"Missing required env var: {key}")
    return v


def upload(groups, replace=False):
    from supabase import create_client
    url = env("SUPABASE_URL", True)
    key = env("SUPABASE_ANON_KEY", True)
    email = env("APP_EMAIL", True)
    password = env("APP_PASSWORD", True)

    sb = create_client(url, key)
    auth = sb.auth.sign_in_with_password({"email": email, "password": password})
    sb.postgrest.auth(auth.session.access_token)
    user_id = auth.user.id

    imported = 0
    for meta, rows in groups:
        if not meta.get("collected_on"):
            print("  skipping a group with no collection date."); continue
        ref = meta.get("import_ref") or f"lab:{meta['collected_on']}"
        existing = sb.table("lab_reports").select("id").eq("user_id", user_id).eq("import_ref", ref).execute()
        if existing.data:
            if not replace:
                print(f"  {ref}: already imported — skipping (use --replace to overwrite).")
                continue
            for r in existing.data:
                sb.table("lab_reports").delete().eq("id", r["id"]).execute()   # cascades to results
            print(f"  {ref}: replacing existing report.")

        rep = sb.table("lab_reports").insert({
            "user_id": user_id, "collected_on": meta["collected_on"], "source": meta.get("source"),
            "physician": meta.get("physician"), "fasting": meta.get("fasting"), "import_ref": ref,
        }).execute()
        report_id = rep.data[0]["id"]
        payload = [{**r, "user_id": user_id, "report_id": report_id} for r in rows]
        if payload:
            sb.table("lab_results").insert(payload).execute()
        imported += 1
        print(f"  {meta['collected_on']} ({meta.get('source')}): {len(payload)} markers.")
    print(f"Done. {imported} report(s) imported.")


def main():
    args = sys.argv[1:]
    dry = "--dry-run" in args
    replace = "--replace" in args
    paths = [a for a in args if not a.startswith("--")]
    if not paths:
        sys.exit("Usage: python labs_sync/import_labs.py [--dry-run] [--replace] <lab.pdf>")

    fmt, groups = parse_pdf(paths[0])
    total = sum(len(rows) for _, rows in groups)
    print(f"Detected format: {fmt}. {len(groups)} report(s), {total} markers total.")
    for meta, rows in groups:
        print(f"  • {meta.get('collected_on')}  {meta.get('source')}  "
              f"({len(rows)} markers)  ref={meta.get('import_ref')}")
    if dry:
        print(json.dumps([{"meta": m, "results": r} for m, r in groups], indent=1, default=str))
        return
    upload(groups, replace=replace)


if __name__ == "__main__":
    main()
