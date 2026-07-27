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
//   mode: "scrape"  → a recipe page URL  → { name, servings, instructions,
//                                            ingredients:[...], note }
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

// Only reached when a page has no schema.org Recipe on it. The model is reading
// stripped page text, so most of what it sees is navigation, ad slots, comments
// and the story above the recipe — saying so is what keeps "Jump to Recipe" and
// "You might also like" out of the ingredient list.
const SCRAPE_PROMPT =
  `The text below is a web page that contains a recipe. Extract the recipe, ignoring navigation, adverts, comments, related-recipe links and the author's story.
Return ONLY valid JSON, no markdown:
{"name":"...","servings":4,"total_minutes":45,"ingredients":["1 lb ground beef","2 cans kidney beans"],"instructions":"1. Brown the beef.\\n2. Add the beans."}
- ingredients: one string per ingredient, copied as written including the amount.
- instructions: the method as plain text, one numbered step per line.
- servings / total_minutes: numbers, or null when the page doesn't say.
- If there is no recipe on the page at all, return {"name":null,"ingredients":[]}.`;

// ── Anthropic call ──────────────────────────────────────────────────────────
// A scraped page carries the method as well as the ingredients, which is more
// output than the 2k the other modes need — hence the override.
async function callClaude(content: unknown, maxTokens = 2000): Promise<string> {
  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY!,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: maxTokens,
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
    // Grams per serving, when OFF has parsed it out of serving_size for us.
    // The client defaults the amount-eaten field to one serving when it's here.
    serving_quantity: num(p.serving_quantity),
    cal_100g: num(n["energy-kcal_100g"]),
    protein_100g: num(n["proteins_100g"]),
    fat_100g: num(n["fat_100g"]),
    carbs_100g: num(n["carbohydrates_100g"]),
    fiber_100g: num(n["fiber_100g"]),
  };
}

// ── Scraping a recipe page ──────────────────────────────────────────────────
//
// This has to happen here rather than in the browser: a recipe site sends no
// CORS headers, so fetching one from the page is blocked outright. Server-side
// there is no such wall — which is exactly why the URL needs checking before
// it's followed.
//
// The guard is a host denylist plus manual redirect handling, so a redirect to
// somewhere private is refused rather than silently followed. It does NOT stop
// a hostname that resolves to a private address; catching that means resolving
// DNS ourselves and pinning the connection to the address we checked, which
// Deno's fetch won't do. For a personal app fetching recipe sites the denylist
// is the proportionate guard — say so plainly rather than implying more.
function checkedUrl(raw: string): URL {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new Error("That doesn't look like a web address.");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") {
    throw new Error("Only http:// and https:// links can be read.");
  }
  const h = u.hostname.toLowerCase();
  const blocked = h === "localhost" || h.endsWith(".localhost") ||
    h.endsWith(".local") || h.endsWith(".internal") ||
    h === "metadata.google.internal" ||
    h.startsWith("[");                       // IPv6 literal — never a recipe site
  const v4 = h.match(/^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/);
  const a = v4 ? Number(v4[1]) : -1, b = v4 ? Number(v4[2]) : -1;
  const privateV4 = v4 !== null && (
    a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 192 && b === 168) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 169 && b === 254)                 // link-local, incl. cloud metadata
  );
  if (blocked || privateV4) {
    throw new Error("That address can't be read from here.");
  }
  return u;
}

const MAX_PAGE_BYTES = 3_000_000;

async function fetchPage(start: URL): Promise<string> {
  let url = start;
  // Redirects are followed by hand so each hop gets the same check as the URL
  // that was typed. Following automatically would let a public URL bounce us
  // somewhere the check was meant to refuse.
  for (let hop = 0; hop < 4; hop++) {
    const res = await fetch(url.href, {
      redirect: "manual",
      signal: AbortSignal.timeout(15000),
      headers: {
        // Plenty of recipe sites 403 an unrecognised client outright.
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
          "(KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "en-US,en;q=0.9",
      },
    });

    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      await res.body?.cancel();
      if (!loc) throw new Error("That link redirects to nowhere.");
      url = checkedUrl(new URL(loc, url).href);
      continue;
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(
        `That page wouldn't load (${res.status}). Some sites block this — ` +
          `copy the ingredients across by hand instead.`,
      );
    }

    const size = Number(res.headers.get("content-length") || 0);
    if (size > MAX_PAGE_BYTES) {
      await res.body?.cancel();
      throw new Error("That page is too big to read.");
    }
    return (await res.text()).slice(0, MAX_PAGE_BYTES);
  }
  throw new Error("That link redirects too many times.");
}

function decodeEntities(s: string): string {
  return s
    .replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">").replace(/&quot;/gi, '"').replace(/&#0?39;/g, "'")
    .replace(/&apos;/gi, "'").replace(/&frac12;/gi, "1/2")
    .replace(/&frac14;/gi, "1/4").replace(/&frac34;/gi, "3/4")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)));
}

function stripTags(html: string): string {
  return decodeEntities(
    html
      .replace(/<(script|style|noscript|svg|nav|footer|header|form)[\s\S]*?<\/\1>/gi, " ")
      .replace(/<!--[\s\S]*?-->/g, " ")
      .replace(/<\/(p|div|li|tr|h[1-6]|br)>/gi, "\n")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<[^>]+>/g, " "),
  ).replace(/[ \t ]+/g, " ").replace(/\n\s*\n\s*\n+/g, "\n\n").trim();
}

// ── schema.org Recipe, when the page has one ────────────────────────────────
// Most recipe sites publish one, and it's strictly better than reading the
// prose: the amounts are already separated from the story, and it costs no
// model call. The model is the fallback, not the first move.
type Json = Record<string, unknown>;

function hasType(node: Json, want: string): boolean {
  const t = node["@type"];
  return typeof t === "string"
    ? t === want
    : Array.isArray(t) && t.some((x) => x === want);
}

function findRecipe(node: unknown, depth = 0): Json | null {
  if (depth > 6 || node === null || typeof node !== "object") return null;
  if (Array.isArray(node)) {
    for (const item of node) {
      const hit = findRecipe(item, depth + 1);
      if (hit) return hit;
    }
    return null;
  }
  const obj = node as Json;
  if (hasType(obj, "Recipe")) return obj;
  // @graph is how most CMS plugins wrap it; the rest of the walk catches the
  // sites that nest it somewhere of their own devising.
  for (const key of ["@graph", "mainEntity", "itemListElement"]) {
    const hit = findRecipe(obj[key], depth + 1);
    if (hit) return hit;
  }
  return null;
}

function jsonLdRecipe(html: string): Json | null {
  const re =
    /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    try {
      const hit = findRecipe(JSON.parse(decodeEntities(m[1].trim())));
      if (hit) return hit;
    } catch {
      // A malformed block on the page is not a reason to give up on the page.
    }
  }
  return null;
}

// "PT1H30M" → 90. Returns null for anything it can't read, which the caller
// treats the same as the page not saying.
function isoMinutes(v: unknown): number | null {
  if (typeof v === "number" && v > 0) return Math.round(v);
  if (typeof v !== "string") return null;
  const m = v.match(/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)/i);
  if (!m) return null;
  const mins = Number(m[1] || 0) * 1440 + Number(m[2] || 0) * 60 + Number(m[3] || 0);
  return mins > 0 ? mins : null;
}

// recipeYield is "4 servings", "4", 4, or ["4","4 servings"] depending on the
// site. Only the first number in it is ever useful.
function yieldServings(v: unknown): number | null {
  const raw = Array.isArray(v) ? v[0] : v;
  if (typeof raw === "number") return raw > 0 ? raw : null;
  if (typeof raw !== "string") return null;
  const n = parseFloat((raw.match(/\d+(\.\d+)?/) || [""])[0]);
  return n > 0 ? n : null;
}

// recipeInstructions comes as a string, a list of strings, HowToStep objects,
// or HowToSections wrapping HowToSteps. Flatten whichever it is into lines.
function instructionLines(v: unknown, depth = 0): string[] {
  if (depth > 4 || v === null || v === undefined) return [];
  if (typeof v === "string") {
    return stripTags(v).split("\n").map((s) => s.trim()).filter(Boolean);
  }
  if (Array.isArray(v)) return v.flatMap((x) => instructionLines(x, depth + 1));
  if (typeof v === "object") {
    const o = v as Json;
    if (o.itemListElement) {
      const heading = typeof o.name === "string" ? [stripTags(o.name)] : [];
      return heading.concat(instructionLines(o.itemListElement, depth + 1));
    }
    const t = o.text ?? o.name ?? o.description;
    return typeof t === "string" ? instructionLines(t, depth + 1) : [];
  }
  return [];
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

    if (mode === "scrape") {
      const url = checkedUrl(String(body.url || "").trim());
      const html = await fetchPage(url);

      // Two ways in. The structured one is free and exact, so it's tried first;
      // the model only reads the page when the site publishes no Recipe.
      let name: string | null = null;
      let servings: number | null = null;
      let totalMinutes: number | null = null;
      let instructions = "";
      let lines: string[] = [];
      let source = "schema";

      const ld = jsonLdRecipe(html);
      if (ld && Array.isArray(ld.recipeIngredient) && ld.recipeIngredient.length) {
        name = typeof ld.name === "string" ? stripTags(ld.name) : null;
        servings = yieldServings(ld.recipeYield);
        totalMinutes = isoMinutes(ld.totalTime) ??
          ((isoMinutes(ld.prepTime) ?? 0) + (isoMinutes(ld.cookTime) ?? 0) || null);
        instructions = instructionLines(ld.recipeInstructions).join("\n");
        lines = (ld.recipeIngredient as unknown[])
          .filter((x): x is string => typeof x === "string")
          .map((s) => stripTags(s)).filter(Boolean);
      } else {
        source = "model";
        const text = stripTags(html).slice(0, 24000);
        if (text.length < 200) {
          throw new Error(
            "There was nothing readable on that page. Some sites build the " +
              "recipe in the browser — paste the ingredients in instead.",
          );
        }
        const out = parseJSON(
          await callClaude(`${SCRAPE_PROMPT}\n\nPage text:\n${text}`, 4000),
        ) as Json;
        name = typeof out.name === "string" ? out.name : null;
        servings = yieldServings(out.servings);
        totalMinutes = isoMinutes(out.total_minutes);
        instructions = typeof out.instructions === "string" ? out.instructions : "";
        lines = Array.isArray(out.ingredients)
          ? (out.ingredients as unknown[])
            .filter((x): x is string => typeof x === "string").map((s) => s.trim())
            .filter(Boolean)
          : [];
      }

      if (!lines.length) {
        throw new Error(
          "No ingredient list turned up on that page. Check the link points " +
            "at the recipe itself, or paste the ingredients in instead.",
        );
      }

      // Whichever route got us here, the ingredients are still just text. The
      // weights and macros come from the same estimator the typed-in and
      // photographed recipes use, so a scraped recipe lands in exactly the
      // shape the builder already knows how to edit.
      const est = parseJSON(
        await callClaude(`${RECIPE_PROMPT}\n\nRecipe ingredients:\n${lines.join("\n")}`, 4000),
      ) as Json;

      return json({
        name,
        servings,
        total_minutes: totalMinutes,
        instructions,
        source_url: url.href,
        ingredients: est.ingredients ?? [],
        note: typeof est.note === "string" ? est.note : "",
        // Which route read the page. The client says "read from the page" vs
        // "estimated from the page" so a wrong ingredient has an explanation.
        parsed_by: source,
      });
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
