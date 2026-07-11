// ============================================================================
// ai-parse — Supabase Edge Function (Deno)
//
// One function, switched by `mode`, that does the model-backed parsing for the
// nutrition tracker. The browser CANNOT call api.anthropic.com directly (CORS
// is blocked on iOS, and the API key must never ship to a client), so every
// model call goes through here. The Anthropic key lives in Supabase secrets.
//
//   mode: "meal"    → free text          → { items:[...], note }
//   mode: "label"   → base64 panel image → { productName, caloriesPerServing, ... }
//   mode: "recipe"  → ingredient list    → { ingredients:[...], note }
//   mode: "barcode" → barcode string     → food per-100g shape via Open Food Facts
//
// Deploy:  supabase functions deploy ai-parse
// Secret:  supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
// ============================================================================

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = "claude-sonnet-4-6";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// ── Prompts (lifted verbatim from the prototype) ────────────────────────────
const PARSE_PROMPT =
  `You are a nutrition estimator. Break the food description into individual line items.
For each item give: name, qty (number), unit (short string like "cup","oz","g","piece","slice","serving"), and totals for that quantity: calories (integer), protein (g), fat (g), carbs (g), fiber (g).
If a quantity isn't stated, assume one typical serving.
ALWAYS fill calories AND protein, fat, carbs and fiber with your best numeric estimate for the stated quantity. Never leave a macro at 0 unless the food genuinely contains none of it, and never put nutrition numbers only in the note — every number goes in its field.
Return ONLY valid JSON, no markdown, no commentary, exactly:
{"items":[{"name":"...","qty":1,"unit":"...","calories":0,"protein":0,"fat":0,"carbs":0,"fiber":0}],"note":"one short sentence on any big assumption, or empty string"}`;

const LABEL_PROMPT =
  `Read this Nutrition Facts label image.
Return ONLY valid JSON, no markdown:
{"productName": string or null, "servingSize": string or null, "caloriesPerServing": number or null, "servingsPerContainer": number or null, "proteinPerServing": number or null, "fatPerServing": number or null, "carbsPerServing": number or null, "fiberPerServing": number or null}
Macros in grams. Use null for anything you cannot read clearly.`;

const RECIPE_PROMPT =
  `You are a recipe nutrition estimator. Given a recipe's ingredient list, return each ingredient with an estimated weight in grams and its nutrition totals (not per 100g).
Return ONLY valid JSON, no markdown:
{"ingredients":[{"name":"...","qty":1,"unit":"cup","grams":120,"calories":455,"protein":12,"fat":2,"carbs":95,"fiber":4}],"note":"one short sentence on any big assumption, or empty string"}
- grams = estimated weight of that quantity of that ingredient.
- calories/protein/fat/carbs/fiber = totals for the stated quantity. Macros in grams. Integers are fine.
Use realistic USDA-style values.`;

const RECIPE_PHOTO_PROMPT =
  `This image shows a recipe (an ingredient list, possibly with instructions). Read each ingredient and its amount, then estimate each one's weight in grams and its nutrition totals (not per 100g).
Return ONLY valid JSON, no markdown:
{"ingredients":[{"name":"...","qty":1,"unit":"cup","grams":120,"calories":455,"protein":12,"fat":2,"carbs":95,"fiber":4}],"note":"one short sentence on anything unreadable or assumed, or empty string"}
- grams = estimated weight of that quantity of that ingredient.
- calories/protein/fat/carbs/fiber = totals for the stated quantity. Macros in grams. Integers are fine.
Use realistic USDA-style values. If an amount is unreadable, assume a sensible default and mention it in note.`;

const BARCODE_PHOTO_PROMPT =
  `This image contains a product barcode (UPC or EAN). Return ONLY the barcode number — the digits printed beneath the bars — as a plain string of digits, no spaces and no other text. If you cannot read the digits clearly, return an empty string.`;

// ── Anthropic call ──────────────────────────────────────────────────────────
async function callClaude(content: unknown): Promise<string> {
  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY!,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 2000,
      messages: [{ role: "user", content }],
    }),
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 200);
    throw new Error(`Anthropic ${res.status} — ${detail}`);
  }
  const data = await res.json();
  if (!data || !Array.isArray(data.content)) {
    throw new Error("Empty/odd response from model.");
  }
  return data.content
    .filter((b: { type: string }) => b.type === "text")
    .map((b: { text: string }) => b.text)
    .join("\n");
}

// Strip ```json fences and parse. The model usually returns bare JSON, but it
// sometimes wraps it in prose ("Here is the ...") despite the instructions —
// so if a straight parse fails, fall back to the outermost {...}/[...] span.
function parseJSON(text: string): unknown {
  const clean = text.replace(/```json/gi, "").replace(/```/g, "").trim();
  try {
    return JSON.parse(clean);
  } catch {
    const first = clean.search(/[{[]/);
    const last = Math.max(clean.lastIndexOf("}"), clean.lastIndexOf("]"));
    if (first !== -1 && last > first) {
      return JSON.parse(clean.slice(first, last + 1));
    }
    throw new Error("The estimate didn't come back as usable data. Try again.");
  }
}

// ── Open Food Facts → foods per-100g shape ──────────────────────────────────
async function lookupBarcode(barcode: string): Promise<unknown> {
  const res = await fetch(
    `https://world.openfoodfacts.org/api/v2/product/${
      encodeURIComponent(barcode)
    }.json`,
  );
  const data = await res.json();
  if (data?.status !== 1 || !data?.product) {
    throw new Error(`Barcode ${barcode} isn't in Open Food Facts. Use Photo label instead.`);
  }
  const p = data.product;
  const n = p.nutriments || {};
  const num = (v: unknown) => (typeof v === "number" ? v : Number(v) || null);
  return {
    name: p.product_name || p.generic_name || "Packaged item",
    kind: "packaged",
    barcode,
    serving_size: p.serving_size || null,
    cal_100g: num(n["energy-kcal_100g"]),
    protein_100g: num(n["proteins_100g"]),
    fat_100g: num(n["fat_100g"]),
    carbs_100g: num(n["carbohydrates_100g"]),
    fiber_100g: num(n["fiber_100g"]),
  };
}

// ── Handler ─────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!ANTHROPIC_API_KEY) return json({ error: "ANTHROPIC_API_KEY not set" }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const mode = body.mode;

  try {
    if (mode === "meal") {
      const text = String(body.text || "").trim();
      if (!text) return json({ error: "Missing text" }, 400);
      const out = parseJSON(
        await callClaude(`${PARSE_PROMPT}\n\nFood description: ${text}`),
      );
      return json(out);
    }

    if (mode === "recipe") {
      const image = String(body.image || ""); // base64, no data: prefix
      if (image) {
        const mediaType = String(body.media_type || "image/jpeg");
        const out = parseJSON(
          await callClaude([
            { type: "image", source: { type: "base64", media_type: mediaType, data: image } },
            { type: "text", text: RECIPE_PHOTO_PROMPT },
          ]),
        );
        return json(out);
      }
      const text = String(body.text || "").trim();
      if (!text) return json({ error: "Missing recipe text or image" }, 400);
      const out = parseJSON(
        await callClaude(`${RECIPE_PROMPT}\n\nRecipe ingredients:\n${text}`),
      );
      return json(out);
    }

    if (mode === "label") {
      const image = String(body.image || ""); // base64, no data: prefix
      const mediaType = String(body.media_type || "image/jpeg");
      if (!image) return json({ error: "Missing image" }, 400);
      const out = parseJSON(
        await callClaude([
          { type: "image", source: { type: "base64", media_type: mediaType, data: image } },
          { type: "text", text: LABEL_PROMPT },
        ]),
      );
      return json(out);
    }

    if (mode === "barcode") {
      let barcode = String(body.barcode || "").trim();
      if (!barcode && body.image) {
        const mediaType = String(body.media_type || "image/jpeg");
        const read = await callClaude([
          { type: "image", source: { type: "base64", media_type: mediaType, data: String(body.image) } },
          { type: "text", text: BARCODE_PHOTO_PROMPT },
        ]);
        barcode = (read.match(/\d/g) || []).join(""); // keep digits only
      }
      if (!barcode) return json({ error: "Couldn't read a barcode number from that photo. Try a clearer, closer shot." }, 400);
      if (barcode.length < 8 || barcode.length > 14) {
        return json({ error: `Read "${barcode}", which doesn't look like a barcode. Try again.` }, 400);
      }
      return json(await lookupBarcode(barcode));
    }

    return json({ error: `Unknown mode: ${mode}` }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || "Parse failed" }, 502);
  }
});
