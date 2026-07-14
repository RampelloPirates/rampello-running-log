// ============================================================================
// gym — Supabase Edge Function (Deno)
//
// Two jobs, switched by `mode`:
//
//   mode: "inventory" → photos of a gym → the equipment that's in it
//   mode: "exercises" → a gym's equipment + a muscle group → what you can do
//
// Everything else (creating gyms, editing the equipment list, logging sets) is
// plain table work the browser does directly through RLS. Only the two jobs
// that need Claude live here.
//
// Deploy:  supabase functions deploy gym
// Secrets: ANTHROPIC_API_KEY   (SUPABASE_URL / SERVICE_ROLE_KEY are injected)
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

const admin = createClient(SUPABASE_URL, SERVICE_KEY);

// Anthropic rejects a media_type that doesn't match the bytes, and a phone
// gives you PNG or HEIC-converted-JPEG depending on its mood. Sniff it.
function sniffMedia(b64: string, fallback: string): string {
  if (b64.startsWith("/9j/")) return "image/jpeg";
  if (b64.startsWith("iVBORw0KGgo")) return "image/png";
  if (b64.startsWith("R0lGOD")) return "image/gif";
  if (b64.startsWith("UklGR")) return "image/webp";
  return fallback;
}

async function post(body: Record<string, unknown>) {
  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY!,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`Anthropic ${res.status} — ${(await res.text()).slice(0, 200)}`);
  }
  return await res.json();
}

function textOf(data: any) {
  const text = (data.content || [])
    .filter((b: { type: string }) => b.type === "text")
    .map((b: { text: string }) => b.text)
    .join("");
  return JSON.parse(text);   // schema-constrained — safe to parse directly
}

async function claude(body: Record<string, unknown>) {
  const data = await post(body);
  if (data.stop_reason === "refusal") throw new Error("The model declined that request.");
  return textOf(data);
}

// Same, but the model may reach for web search on the way. A server tool call
// ends the turn with stop_reason "pause_turn" — the results are already in the
// response, so we hand the whole thing back and let it carry on.
async function claudeSearching(body: Record<string, unknown>) {
  const messages = [...(body.messages as any[])];
  for (let i = 0; i < 4; i++) {
    const data = await post({ ...body, messages });
    if (data.stop_reason === "refusal") throw new Error("The model declined that request.");
    if (data.stop_reason !== "pause_turn") return textOf(data);
    messages.push({ role: "assistant", content: data.content });
  }
  throw new Error("Gave up looking that exercise up.");
}

// ── Inventory: photos → equipment ──────────────────────────────────────────
const EQUIPMENT_CATEGORIES = ["free_weights", "machine", "cable", "rack", "cardio", "accessory"];

const INVENTORY_PROMPT =
  `These are photos of a gym. List the training equipment you can see.

For each piece:
- "name": what it is, in the plainest name a lifter would use — "flat bench", "cable crossover", "leg press", "dumbbells", "squat rack", "assisted pull-up machine".
- "category": one of free_weights, machine, cable, rack, cardio, accessory.
- "detail": the thing that decides whether an exercise is actually possible here. Weight ranges above all — "5–50 lb, in 5 lb steps". Also: "no safety bars", "single stack", "fixed bar path". Null if there's nothing worth saying.

Rules:
- One entry per KIND of equipment, not per unit. Eight treadmills is one entry: "treadmill".
- Read the dumbbell/plate racks carefully and give the range you can actually see. "Dumbbells" without a range is nearly useless for programming — it's the difference between a working set and a warm-up.
- If a machine's label is legible, use it. If not, name it by what it obviously does.
- Do NOT list equipment you can't see just because a gym like this usually has it. An imagined cable machine produces a workout the user can't do.
- Ignore people, décor, mirrors, water fountains, signage, lockers.`;

const INVENTORY_SCHEMA = {
  type: "object",
  properties: {
    equipment: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          category: { enum: EQUIPMENT_CATEGORIES },
          detail: { anyOf: [{ type: "string" }, { type: "null" }] },
        },
        required: ["name", "category", "detail"],
        additionalProperties: false,
      },
    },
  },
  required: ["equipment"],
  additionalProperties: false,
};

// ── Exercises: equipment + muscle group → what you can actually do ─────────
const EXERCISE_PROMPT =
  `Below is the complete equipment list for one gym, and a muscle group the user wants to train.

Give them every worthwhile exercise for that muscle group that this gym can actually support, grouped by the equipment it uses.

Hard rules:
- ONLY use equipment on the list. This is the whole point. If there's no cable machine, there are no cable exercises — not one, not as a "if available" note.
- STAY ON the muscle they asked for. If they said "Quads", give quad work — not a general leg day. Compounds that hit it hard are welcome (a squat is quad work), but an exercise whose main job is elsewhere is not: no leg curls under "Quads", no calf raises, no "while you're here". "Hamstrings" means hamstrings. "Triceps" means triceps. The whole reason they picked a specific muscle is that they didn't want the whole limb.
- Bodyweight is always available, whatever the list says. Include bodyweight work under an "Bodyweight" equipment group where it's genuinely useful for this muscle group.
- Respect the "detail" notes. If the dumbbells stop at 50 lb, don't prescribe a movement that only works past that for most people. If a rack has no safety bars, don't program to failure under a loaded bar.
- If the gym is too sparse to train this muscle group well, SAY SO in "note" and give the best available compromise. Do not pad the list with things that don't work here.

For each exercise:
- "name": the standard name a lifter would search for.
- "target": the specific part it hits — "upper chest", "long head of the triceps", "glute medius". Say why this exercise is on the list.
- "sets" and "reps": a sensible prescription ("3", "8–12").
- "cue": ONE short form cue that actually prevents the usual mistake. Not a full description.

Order each group's exercises best-first: compound before isolation, and the ones that use the gym's better equipment first.`;

const EXERCISE_SCHEMA = {
  type: "object",
  properties: {
    groups: {
      type: "array",
      items: {
        type: "object",
        properties: {
          equipment: { type: "string" },
          exercises: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                target: { type: "string" },
                sets: { type: "string" },
                reps: { type: "string" },
                cue: { type: "string" },
              },
              required: ["name", "target", "sets", "reps", "cue"],
              additionalProperties: false,
            },
          },
        },
        required: ["equipment", "exercises"],
        additionalProperties: false,
      },
    },
    note: { anyOf: [{ type: "string" }, { type: "null" }] },
  },
  required: ["groups", "note"],
  additionalProperties: false,
};

// ── Can this gym do that favourite? ───────────────────────────────────────
// Not a string comparison. A favourite needs "Dumbbells"; the gym has
// "dumbbells (10–75 lb)" and "adjustable bench". Whether the workout survives
// the move is a judgement about equivalence and load, so the model makes it.
const MATCH_PROMPT =
  `Here is a gym's equipment, and some saved workouts the user likes. For each workout, decide whether they could actually do it AT THIS GYM.

- "doable": true if every exercise can be done here, OR if the ones that can't have a genuine equivalent that hits the same muscle the same way. Otherwise false.
- "why": one short line. If it works, say what makes it work ("the dumbbells go to 75, and there's a bench"). If it doesn't, say exactly what's missing ("no cable machine — three of the five exercises are cable work").
- "swaps": for any exercise that can't be done as written but has a good equivalent here, give the replacement. Empty if nothing needs swapping.

Be strict. The whole value of this is that it doesn't hand someone a workout they'll get to the gym and find they can't do. A near-miss substitution is fine; a "you could sort of approximate it" is not — that's a false. And bodyweight is always available anywhere.`;

const MATCH_SCHEMA = {
  type: "object",
  properties: {
    matches: {
      type: "array",
      items: {
        type: "object",
        properties: {
          favorite_id: { type: "string" },
          doable: { type: "boolean" },
          why: { type: "string" },
          swaps: {
            type: "array",
            items: {
              type: "object",
              properties: {
                exercise: { type: "string" },
                use_instead: { type: "string" },
              },
              required: ["exercise", "use_instead"],
              additionalProperties: false,
            },
          },
        },
        required: ["favorite_id", "doable", "why", "swaps"],
        additionalProperties: false,
      },
    },
  },
  required: ["matches"],
  additionalProperties: false,
};

// ── Lookup: a name the user typed → what it is and what it trains ──────────
// The generated menu is a starting point, not a cage. People have exercises they
// already do — from a coach, a physio, a video, a friend at the gym — and the
// point of a log is to log what you actually did, not what an app suggested.
const MUSCLE_ENUM = [
  "Chest", "Shoulders", "Triceps", "Back", "Biceps", "Forearms",
  "Quads", "Hamstrings", "Glutes", "Calves", "Legs (all)", "Core", "Full body",
];

const LOOKUP_PROMPT =
  `The user typed the name of an exercise they want to add to their workout. Work out what it is.

- "found": false ONLY if this isn't an exercise at all, or you genuinely cannot establish what it is. Then leave the rest empty and put the reason in "warn".
- "name": the standard name for it, properly spelled. They may have typed it wrong, abbreviated it ("RDL", "OHP"), or used gym slang.
- "muscle": the ONE group from the list that this exercise primarily trains. Primarily. A deadlift is Hamstrings, not Full body, unless it truly is a whole-body movement.
- "target": the specific part it hits — "long head of the triceps", "glute medius".
- "equipment": what it needs. Look at the gym's equipment list below and use THAT gym's wording where the exercise really does use that item, so it files under the right heading. If it needs nothing, "Bodyweight".
- "sets" / "reps": a sensible prescription ("3", "8–12").
- "cue": ONE short form cue that prevents the usual mistake.
- "in_gym": true if this gym has what the exercise needs (bodyweight always counts as available). If false, still fill everything in — they asked for it, and they may know something the equipment list doesn't — but say what's missing in "warn".

If the name is one you don't recognise, search the web before answering. New exercises, physio movements and regional names are real, and guessing at one produces a plausible-sounding lie. Only search if you actually need to — you already know the overwhelming majority of exercises.`;

const LOOKUP_SCHEMA = {
  type: "object",
  properties: {
    found: { type: "boolean" },
    name: { type: "string" },
    muscle: { enum: MUSCLE_ENUM.concat([""]) },
    target: { type: "string" },
    equipment: { type: "string" },
    sets: { type: "string" },
    reps: { type: "string" },
    cue: { type: "string" },
    in_gym: { type: "boolean" },
    warn: { type: "string" },
  },
  required: ["found", "name", "muscle", "target", "equipment", "sets", "reps", "cue", "in_gym", "warn"],
  additionalProperties: false,
};

async function userFromJWT(req: Request): Promise<string> {
  const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data?.user) throw new Error("Not signed in.");
  return data.user.id;
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

  try {
    const userId = await userFromJWT(req);

    // ---- inventory: photos → equipment -----------------------------------
    if (body.mode === "inventory") {
      const gymId = String(body.gym_id || "");
      if (!gymId) return json({ error: "Which gym?" }, 400);

      const images: string[] = body.images || (body.image ? [body.image] : []);
      const text = String(body.text || "").trim();
      if (!images.length && !text) return json({ error: "Send a photo or type what's there." }, 400);

      const content: unknown[] = images.map((b64) => ({
        type: "image",
        source: { type: "base64", media_type: sniffMedia(b64, "image/jpeg"), data: b64 },
      }));
      content.push({
        type: "text",
        text: text
          ? `${INVENTORY_PROMPT}\n\nThey also typed this about the gym — treat it as equipment that IS there, even if it isn't in the photos:\n${text}`
          : INVENTORY_PROMPT,
      });

      const out = await claude({
        model: MODEL,
        max_tokens: 4000,
        thinking: { type: "adaptive" },
        output_config: { format: { type: "json_schema", schema: INVENTORY_SCHEMA } },
        messages: [{ role: "user", content }],
      });

      // The unique index on (gym_id, lower(name)) does the deduping: the same
      // rack shot from two angles collapses to one row on its own.
      const added: string[] = [];
      for (const e of out.equipment || []) {
        const name = String(e.name || "").trim();
        if (!name) continue;
        const ins = await admin.from("gym_equipment").insert({
          user_id: userId,
          gym_id: gymId,
          name,
          category: e.category || null,
          detail: e.detail || null,
        }).select("id").single();
        if (!ins.error) added.push(name);
      }

      return json({ added, seen: (out.equipment || []).length });
    }

    // ---- exercises: equipment + muscle group → menu ------------------------
    if (body.mode === "exercises") {
      const gymId = String(body.gym_id || "");
      const muscle = String(body.muscle || "").trim();
      if (!gymId || !muscle) return json({ error: "Need a gym and a muscle group." }, 400);

      const { data: kit } = await admin
        .from("gym_equipment").select("name, category, detail").eq("gym_id", gymId);

      // Service-role bypasses RLS, so check ownership by hand before we hand
      // this gym's contents back to whoever asked.
      const { data: gym } = await admin
        .from("gyms").select("id, name, user_id").eq("id", gymId).single();
      if (!gym || gym.user_id !== userId) return json({ error: "Not your gym." }, 403);

      const list = (kit || []).length
        ? (kit || []).map((e: any) =>
          `- ${e.name}${e.detail ? ` (${e.detail})` : ""}${e.category ? ` [${e.category}]` : ""}`
        ).join("\n")
        : "(nothing inventoried — assume bodyweight only)";

      const out = await claude({
        model: MODEL,
        max_tokens: 8000,
        thinking: { type: "adaptive" },
        output_config: { format: { type: "json_schema", schema: EXERCISE_SCHEMA } },
        messages: [{
          role: "user",
          content:
            `${EXERCISE_PROMPT}\n\nGym: ${gym.name}\n\nEquipment:\n${list}\n\nMuscle group: ${muscle}`,
        }],
      });

      return json({ groups: out.groups || [], note: out.note || null });
    }

    // ---- lookup: a typed exercise name → what it is, what it trains --------
    if (body.mode === "lookup") {
      const gymId = String(body.gym_id || "");
      const q = String(body.query || "").trim();
      if (!gymId || !q) return json({ error: "Type the name of an exercise." }, 400);

      const { data: gym } = await admin
        .from("gyms").select("id, name, user_id").eq("id", gymId).single();
      if (!gym || gym.user_id !== userId) return json({ error: "Not your gym." }, 403);

      const { data: kit } = await admin
        .from("gym_equipment").select("name, detail").eq("gym_id", gymId);
      const kitList = (kit || []).length
        ? (kit || []).map((e: any) => `- ${e.name}${e.detail ? ` (${e.detail})` : ""}`).join("\n")
        : "(nothing inventoried — bodyweight only)";

      const req = {
        model: MODEL,
        max_tokens: 3000,
        thinking: { type: "adaptive" },
        output_config: { format: { type: "json_schema", schema: LOOKUP_SCHEMA } },
        messages: [{
          role: "user",
          content: `${LOOKUP_PROMPT}\n\nGym: ${gym.name}\n\nEquipment:\n${kitList}\n\nThey typed: ${q}`,
        }],
      };

      // Search is a fallback for names the model doesn't know, so it isn't worth
      // failing the whole lookup over. If the tool is unavailable — or the API
      // objects to the combination — answer from what the model already knows,
      // which covers all but the exotic.
      let out;
      try {
        out = await claudeSearching({
          ...req,
          tools: [{ type: "web_search_20260209", name: "web_search", max_uses: 3 }],
        });
      } catch (_e) {
        out = await claude(req);
      }

      return json({ exercise: out });
    }

    // ---- match_favorites: which saved workouts does this gym support? ------
    if (body.mode === "match_favorites") {
      const gymId = String(body.gym_id || "");
      if (!gymId) return json({ error: "Which gym?" }, 400);

      const { data: gym } = await admin
        .from("gyms").select("id, name, user_id").eq("id", gymId).single();
      if (!gym || gym.user_id !== userId) return json({ error: "Not your gym." }, 403);

      const { data: favs } = await admin
        .from("workout_favorites")
        .select("id, name, muscle_group, favorite_exercises(exercise, equipment, position)")
        .eq("user_id", userId);

      if (!favs || !favs.length) return json({ matches: [] });

      const { data: kit } = await admin
        .from("gym_equipment").select("name, detail").eq("gym_id", gymId);

      const kitList = (kit || []).length
        ? (kit || []).map((e: any) => `- ${e.name}${e.detail ? ` (${e.detail})` : ""}`).join("\n")
        : "(nothing inventoried — bodyweight only)";

      const favList = favs.map((f: any) => {
        const ex = (f.favorite_exercises || [])
          .sort((a: any, b: any) => (a.position || 0) - (b.position || 0))
          .map((e: any) => `    · ${e.exercise}${e.equipment ? ` [${e.equipment}]` : ""}`)
          .join("\n");
        return `Workout id ${f.id} — "${f.name}" (${f.muscle_group}):\n${ex}`;
      }).join("\n\n");

      const out = await claude({
        model: MODEL,
        max_tokens: 4000,
        thinking: { type: "adaptive" },
        output_config: { format: { type: "json_schema", schema: MATCH_SCHEMA } },
        messages: [{
          role: "user",
          content: `${MATCH_PROMPT}\n\nGym: ${gym.name}\n\nEquipment:\n${kitList}\n\nSaved workouts:\n${favList}`,
        }],
      });

      return json({ matches: out.matches || [] });
    }

    return json({ error: `Unknown mode: ${body.mode}` }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || "Something went wrong." }, 502);
  }
});
