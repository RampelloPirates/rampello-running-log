// ============================================================================
// medical — Supabase Edge Function (Deno)
//
//   mode: "visit"   → photo of an after-visit summary → structured visit
//   mode: "expense" → photo of a receipt / EOB / bill → structured expense
//
// Extraction only. The page writes the rows itself (RLS), and uploads the
// original image to the `medical` storage bucket — the photo is the asset,
// especially for HSA substantiation.
//
// Deploy:  supabase functions deploy medical
// Secrets: ANTHROPIC_API_KEY
// ============================================================================

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = "claude-opus-4-8";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

function sniffMedia(b64: string, fallback: string): string {
  if (b64.startsWith("/9j/")) return "image/jpeg";
  if (b64.startsWith("iVBORw0KGgo")) return "image/png";
  if (b64.startsWith("R0lGOD")) return "image/gif";
  if (b64.startsWith("UklGR")) return "image/webp";
  return fallback;
}

const VISIT_TYPES = [
  "physical", "sick", "specialist", "follow_up", "urgent_care", "er", "dental",
  "vision", "imaging", "labs", "therapy", "mental_health", "procedure",
  "vaccination", "telehealth", "other",
];

const VISIT_PROMPT =
  `This is an after-visit summary, discharge paperwork, or a doctor's note. Pull the visit out of it.

Get these right, they're the ones that matter later:
- "visit_date": the date of the VISIT, not the date the document was printed. They're often both on the page.
- "visit_type": one of the listed types. A "recheck" or "post-op" is follow_up, not specialist.
- "provider": the clinician actually seen. Not the practice, not the person who signed the printout, not the referring doctor.
- "follow_up_on": if it says "return in 3 months" or "recheck in 6 weeks", COMPUTE the date from the visit date and put it here. This is the single most-forgotten line on any visit summary and the one with real consequences. Put the original wording in "follow_up_note".
- "diagnosis": what they concluded. Include the ICD code if it's printed, in parentheses.
- "instructions": the care plan, in their words, condensed. Don't editorialise.

Also pull anything measured or prescribed at the visit:
- "vitals": blood pressure, weight, pulse, temperature — whatever's on the page. Use the units printed. Blood pressure goes in as systolic/diastolic.
- "prescriptions": drugs prescribed AT THIS VISIT. Include dose and how long for. If it says "10 days" or "30 day supply", put that in "duration_days" as a number — it's what stops a finished course sitting in a daily checklist forever. Null if it's ongoing/indefinite.

And the money, if it's there:
- "amount_owed": what the patient is told they owe / their responsibility. Summaries often carry it. 0 if it isn't shown.

Rules:
- These may be SEVERAL PAGES of one visit. Read them as one document — the date might be on page 1 and the prescriptions on page 3. Don't return one visit per page.
- Anything genuinely not on the page: empty string "" for text, 0 for numbers. Do NOT infer a plausible value — a made-up diagnosis in a medical record is worse than a blank one.
- Don't copy the boilerplate (patient rights, billing notices, "how did we do?").`;

// NO NULL UNIONS ANYWHERE IN HERE. The obvious way to write this schema is
// `anyOf: [{type:"string"},{type:"null"}]` on every optional field — and with
// ~17 of them the API rejects the whole request:
//   "Schemas contains too many parameters with union types … exponential compilation"
// So: everything is a plain string, "" means "not on the page", 0 means "no
// number given", and normalise() below turns those back into nulls. Same
// contract, no unions.
const VISIT_SCHEMA = {
  type: "object",
  properties: {
    visit_date: { type: "string" },      // YYYY-MM-DD, "" if not printed
    visit_type: { enum: VISIT_TYPES },   // 'other' when unclear
    provider: { type: "string" },
    specialty: { type: "string" },
    facility: { type: "string" },
    person: { type: "string" },
    reason: { type: "string" },
    diagnosis: { type: "string" },
    treatment: { type: "string" },
    instructions: { type: "string" },
    referrals: { type: "string" },
    follow_up_on: { type: "string" },
    follow_up_note: { type: "string" },
    // What the patient is told they owe. Often on the summary, and it's the
    // number the receipt will later have to match.
    amount_owed: { type: "number" },     // 0 if not shown
    vitals: {
      type: "array",
      items: {
        type: "object",
        properties: {
          kind: { enum: ["blood_pressure", "weight", "pulse", "temperature"] },
          value: { type: "number" },
          value2: { type: "number" },    // diastolic; 0 when not applicable
          unit: { type: "string" },
        },
        required: ["kind", "value", "value2", "unit"],
        additionalProperties: false,
      },
    },
    prescriptions: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          dose: { type: "string" },
          duration_days: { type: "integer" },   // 0 = ongoing / not stated
        },
        required: ["name", "dose", "duration_days"],
        additionalProperties: false,
      },
    },
  },
  required: [
    "visit_date", "visit_type", "provider", "specialty", "facility", "person",
    "reason", "diagnosis", "treatment", "instructions", "referrals",
    "follow_up_on", "follow_up_note", "amount_owed", "vitals", "prescriptions",
  ],
  additionalProperties: false,
};

const EXPENSE_PROMPT =
  `This is a medical bill, receipt, or insurance EOB. Pull out what's needed to substantiate an HSA claim.

The single most important distinction on this page:
- "billed_amount": what the provider charged, before insurance.
- "paid_amount": what the PATIENT actually paid out of pocket. On an EOB this is "patient responsibility" / "you owe" / "amount you may be billed". On a receipt it's what was actually tendered.

Only paid_amount is reimbursable, and confusing the two is the mistake that matters. If the document shows a charge but NO evidence the patient paid it, set paid_amount to null — a bill is not proof of payment.

- "doc_kind": "receipt" (proof of payment), "eob" (insurer's explanation of benefits), "bill" (a request for payment — NOT proof), or "statement".
- "service_date": the date CARE WAS GIVEN, not the date of the bill and not the date you paid. This is what the IRS cares about.
- "category": office_visit, prescription, dental, vision, lab, imaging, procedure, otc, other.
- "person": the patient's name if printed.

These may be SEVERAL PAGES of one bill — read them as one document, not one expense per page.

Anything not on the page: empty string "" for text, 0 for amounts. Do not guess an amount.`;

// Same rule as above: no unions. "" and 0 mean "not on the page".
const EXPENSE_SCHEMA = {
  type: "object",
  properties: {
    service_date: { type: "string" },
    provider: { type: "string" },
    person: { type: "string" },
    category: {
      enum: ["office_visit", "prescription", "dental", "vision", "lab",
             "imaging", "procedure", "otc", "other"],
    },
    doc_kind: { enum: ["receipt", "eob", "bill", "statement"] },
    billed_amount: { type: "number" },   // 0 if not shown
    paid_amount: { type: "number" },     // 0 if no evidence the patient paid
    note: { type: "string" },
  },
  required: ["service_date", "provider", "person", "category", "doc_kind",
             "billed_amount", "paid_amount", "note"],
  additionalProperties: false,
};

// Turn the schema's sentinels back into the nulls the app expects. Doing this
// here rather than in the page keeps the "" / 0 convention an implementation
// detail of the extractor.
// deno-lint-ignore no-explicit-any
function normalise(o: any): any {
  const out: any = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === "" ) out[k] = null;
    else if (Array.isArray(v)) out[k] = v.map((x) => (typeof x === "object" ? normalise(x) : x));
    else if (typeof v === "number" && v === 0 && k !== "value") out[k] = null;
    else out[k] = v;
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!ANTHROPIC_API_KEY) return json({ error: "ANTHROPIC_API_KEY not set" }, 500);

  let body: Record<string, any>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const isVisit = body.mode === "visit";
  const isExpense = body.mode === "expense";
  if (!isVisit && !isExpense) return json({ error: `Unknown mode: ${body.mode}` }, 400);

  const images: string[] = body.images || (body.image ? [body.image] : []);
  if (!images.length) return json({ error: "Send a photo." }, 400);

  const content: unknown[] = images.map((b64) => ({
    type: "image",
    source: { type: "base64", media_type: sniffMedia(b64, "image/jpeg"), data: b64 },
  }));
  content.push({
    type: "text",
    text: (isVisit ? VISIT_PROMPT : EXPENSE_PROMPT) +
      `\n\nToday is ${new Date().toISOString().slice(0, 10)} — use it to resolve relative dates ("return in 3 months"), never to fill in a date that isn't there.`,
  });

  try {
    const res = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 6000,
        thinking: { type: "adaptive" },
        output_config: {
          format: { type: "json_schema", schema: isVisit ? VISIT_SCHEMA : EXPENSE_SCHEMA },
        },
        messages: [{ role: "user", content }],
      }),
    });
    if (!res.ok) {
      throw new Error(`Anthropic ${res.status} — ${(await res.text()).slice(0, 200)}`);
    }
    const data = await res.json();
    if (data.stop_reason === "refusal") {
      throw new Error("The model declined to read that image.");
    }
    const text = (data.content || [])
      .filter((b: { type: string }) => b.type === "text")
      .map((b: { text: string }) => b.text)
      .join("");
    return json(normalise(JSON.parse(text)));   // schema-constrained; "" / 0 → null
  } catch (e) {
    return json({ error: (e as Error).message || "Couldn't read that." }, 502);
  }
});
