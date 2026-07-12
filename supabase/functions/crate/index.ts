// ============================================================================
// crate — Supabase Edge Function (Deno)
//
// The "bands to check out" pipeline. One function, switched by `mode`:
//
//   mode: "status"     → is Spotify connected? what's the ingest key?
//   mode: "auth_url"   → build the Spotify consent URL
//   mode: "auth_code"  → exchange the ?code from the redirect for tokens
//   mode: "ingest"     → screenshot/text/url → Claude → Spotify → playlist
//
// "ingest" is the one the iOS Shortcut hits. It authenticates with a long-lived
// ingest key (magic-link JWTs expire; a key baked into a Shortcut doesn't).
// Every other mode uses the caller's Supabase session.
//
// Deploy:  supabase functions deploy crate
// Secrets: supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//          supabase secrets set SPOTIFY_CLIENT_ID=...
//          supabase secrets set SPOTIFY_CLIENT_SECRET=...
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const SPOTIFY_CLIENT_ID = Deno.env.get("SPOTIFY_CLIENT_ID");
const SPOTIFY_CLIENT_SECRET = Deno.env.get("SPOTIFY_CLIENT_SECRET");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const MODEL = "claude-opus-4-8";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const SPOTIFY_API = "https://api.spotify.com/v1";

// Where Spotify sends the user back. Must be registered verbatim in the
// Spotify dashboard, and must be https (Spotify banned http://localhost).
// This is the Vercel project's production domain ("jeff-tally") — if the
// domain ever changes, this constant and the Spotify dashboard must both move.
const REDIRECT_URI = "https://jeff-tally.vercel.app/music.html";

// playlist-modify-private is what we actually need (the crate is private);
// -public is included so a public playlist still works if you flip it later.
const SCOPES = "playlist-modify-private playlist-modify-public";

const TOP_TRACKS_PER_ARTIST = 3;

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

// ── Claude: read artists + albums off a screenshot / page / caption ─────────
//
// The first version of this prompt said "if you can't read a name confidently,
// leave it out", which quietly turned this into an OCR job: a cover that is
// pure artwork with no type on it — a photo, a painting — got dropped without a
// word. Half the covers in an emo roundup have no text. So now: recognise the
// record from the artwork, say so with confidence:"guess", and if you truly
// can't place it, COUNT it in `unidentified` rather than vanishing it. A wrong
// guess is cheap (Spotify just won't match it); a silent drop is not.
const EXTRACT_PROMPT =
  `You are reading a music recommendation — a social post, a screenshot of one, or a music blog's roundup.

First scan the whole image and count the records being recommended: every album cover shown, every artist named. Then account for every single one of them. If you see two covers, you must return two entries (or explain the shortfall in "unidentified").

For each recommendation:
- "artist": the artist or band name.
- "album": the album title, ONLY if that specific album is what's being recommended. An album cover displayed IS an album recommendation. If the post highlights the artist generally, or you can't tell which record, use null.
- "confidence": "sure" if you read the name off the image or its caption; "guess" if you recognised the record from the artwork alone.

About album covers:
- Many covers have the artist and title printed on them, often in stylised type. Read them carefully.
- Many covers have NO text at all — just a photograph, a painting, an illustration. This does NOT mean you skip it. Try to recognise the record from the artwork itself and return it with confidence "guess".
- Use the context to help you place a wordless cover: the genre and era the post is about, the caption, and the other records shown alongside it. A wordless snapshot sitting next to a Tigers Jaw record in a post about emo is very likely a well-known emo record — think about which one.
- Prefer a named guess over a shrug. If you have a plausible candidate, return it with confidence "guess". Spotify will simply fail to match a bad guess, and a bad guess is visible and deletable; a missed record is invisible.
- Only when you have no candidate at all, do NOT invent one. Instead add a short description of the cover to "unidentified" ("a washed-out 90s snapshot of two people yelling at a party"), so it can be shown to the user rather than silently dropped.

Do NOT return:
- The poster, the blog, the playlist curator, the DJ or host — they aren't recommendations.
- Posters, prints, records or art visible in the background of a room. That's decor, not a recommendation.
- UI chrome: like/comment counts, "Follow", usernames, hashtags, watermarks.`;

// Structured outputs: the API constrains the response to this schema, so we
// never have to fish JSON out of prose. (This is the bug class that bit
// ai-parse — "Here is the...". It cannot happen here.)
const FINDS_SCHEMA = {
  type: "object",
  properties: {
    finds: {
      type: "array",
      items: {
        type: "object",
        properties: {
          artist: { type: "string" },
          album: { anyOf: [{ type: "string" }, { type: "null" }] },
          confidence: { enum: ["sure", "guess"] },
        },
        required: ["artist", "album", "confidence"],
        additionalProperties: false,
      },
    },
    // Covers it saw but could not put a name to — one short description each.
    // These become rows in the crate, so a missed record is visible and the
    // user can name it themselves instead of never knowing it was there.
    unidentified: { type: "array", items: { type: "string" } },
    // Everything about the post that would help someone else look it up: who
    // published it, the genre/scene, the caption, any date. This is the search
    // query for the second pass — see identifyCovers().
    context: { type: "string" },
  },
  required: ["finds", "unidentified", "context"],
  additionalProperties: false,
};

type Find = { artist: string; album: string | null; confidence?: string };
type Extraction = { finds: Find[]; unidentified: string[]; context: string };

async function extractFinds(content: unknown): Promise<Extraction> {
  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY!,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 4000,
      thinking: { type: "adaptive" },
      output_config: { format: { type: "json_schema", schema: FINDS_SCHEMA } },
      messages: [{ role: "user", content }],
    }),
  });
  if (!res.ok) {
    throw new Error(`Anthropic ${res.status} — ${(await res.text()).slice(0, 200)}`);
  }
  const data = await res.json();
  if (data.stop_reason === "refusal") throw new Error("The model declined to read that image.");

  const text = (data.content || [])
    .filter((b: { type: string }) => b.type === "text")
    .map((b: { text: string }) => b.text)
    .join("");
  const out = JSON.parse(text); // schema-constrained — safe to parse directly
  return {
    finds: (out.finds || []).filter((f: Find) => f.artist?.trim()),
    unidentified: (out.unidentified || [])
      .filter((d: string) => d?.trim())
      .map((d: string) => d.trim().slice(0, 140)),
    context: String(out.context || "").slice(0, 500),
  };
}

// ── Second pass: web-search the covers the first pass couldn't name ─────────
//
// Recognising a wordless cover from memory alone is a bad bet, and a lot of
// covers are wordless. But these posts are almost always about NEW releases,
// which means the press exists — and the screenshot itself carries the search
// terms: the publication's watermark, the caption, and the records we COULD
// read. "What emo albums did Brooklyn Vegan feature this week" is a findable
// list, and the unnamed cover is very likely on it.
//
// So: hand the model the same image, everything we learned about the post, and
// a web_search tool, and let it go look. This runs only when the first pass
// came up short, and only on the background path — it's slow (several searches)
// but nobody is waiting on it.
//
// No output_config here on purpose: server-side tools plus a constrained output
// format is a combination I can't verify from this box, and a 400 would take
// the whole ingest down. The tolerant parser below is the cheaper bet.
async function identifyCovers(
  images: string[],
  mediaType: string,
  unknown: string[],
  context: string,
  known: Find[],
): Promise<Array<{ index: number; artist: string; album: string | null }>> {
  const today = new Date().toISOString().slice(0, 10);
  const knownList = known.length
    ? known.map((f) => (f.album ? `${f.artist} — ${f.album}` : f.artist)).join("; ")
    : "(none)";

  const prompt =
`Today is ${today}. Someone screenshotted a music post and I could not name every record in it. Help me name the rest.

What I could tell about the post: ${context}
Records in it I DID identify: ${knownList}

Covers in the screenshot I could NOT name:
${unknown.map((d, i) => `${i + 1}. ${d}`).join("\n")}

The screenshot is attached. Use web search to work out what these records are.

How to go about it:
- These posts are nearly always about NEW releases — records out in the last few weeks. Search for what came out recently in this scene.
- Try to find the actual post or article. The publication's name, the caption, and the records I already identified are strong search terms — a roundup that includes ${known[0] ? known[0].artist : "these bands"} is probably THE post, and its other entries are your candidates.
- Then match each unnamed cover to a candidate: check the cover art you find described, the era, the scene, the release date.

Return ONLY a JSON object, no prose:
{"covers":[{"index":1,"artist":"Band Name","album":"Album Title or null"}]}

- "index" refers to the numbered list above.
- Use null for "album" only if you're identifying the artist but not a specific record.
- OMIT a cover entirely if you still can't place it. Do not invent a record to fill a slot — a wrong name is worse than an honest gap here.`;

  const content: unknown[] = images.map((b64) => ({
    type: "image",
    source: { type: "base64", media_type: sniffMedia(b64, mediaType), data: b64 },
  }));
  content.push({ type: "text", text: prompt });

  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY!,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 8000,
      thinking: { type: "adaptive" },
      tools: [{ type: "web_search_20260209", name: "web_search", max_uses: 8 }],
      messages: [{ role: "user", content }],
    }),
  });

  if (!res.ok) {
    // A failed second pass is not a failed ingest. The covers stay unidentified
    // and still surface as rows; we just didn't manage to rescue them.
    console.error("identifyCovers failed:", res.status, (await res.text()).slice(0, 300));
    return [];
  }

  const data = await res.json();
  const text = (data.content || [])
    .filter((b: { type: string }) => b.type === "text")
    .map((b: { text: string }) => b.text)
    .join("");

  try {
    const clean = text.replace(/```json/gi, "").replace(/```/g, "").trim();
    const first = clean.search(/[{[]/);
    const last = clean.lastIndexOf("}");
    if (first === -1 || last <= first) return [];
    const out = JSON.parse(clean.slice(first, last + 1));
    return (out.covers || [])
      .filter((c: any) => c && c.artist && Number.isFinite(Number(c.index)))
      .map((c: any) => ({
        index: Number(c.index),
        artist: String(c.artist).trim(),
        album: c.album ? String(c.album).trim() : null,
      }));
  } catch {
    console.error("identifyCovers: unparseable response");
    return [];
  }
}

// The Shortcut can't be trusted to label the image, and Anthropic rejects a
// mismatched media_type outright. Sniff it from the base64 magic bytes instead.
function sniffMedia(b64: string, fallback: string): string {
  if (b64.startsWith("/9j/")) return "image/jpeg";
  if (b64.startsWith("iVBORw0KGgo")) return "image/png";
  if (b64.startsWith("R0lGOD")) return "image/gif";
  if (b64.startsWith("UklGR")) return "image/webp";
  return fallback;
}

// ── Spotify: token plumbing ────────────────────────────────────────────────
const basicAuth = () =>
  "Basic " + btoa(`${SPOTIFY_CLIENT_ID}:${SPOTIFY_CLIENT_SECRET}`);

async function spotifyToken(form: Record<string, string>) {
  const res = await fetch("https://accounts.spotify.com/api/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Authorization: basicAuth(),
    },
    body: new URLSearchParams(form),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error_description || "Spotify auth failed.");
  return data;
}

// Access tokens last an hour. Refresh tokens expire ~6 months after consent and
// refreshing does NOT extend that — so roughly twice a year this throws and you
// re-connect from the Crate page. That's Spotify's design, not a bug here.
async function accessTokenFor(row: Record<string, any>): Promise<string> {
  const stillValid =
    row.spotify_access_token &&
    row.spotify_expires_at &&
    new Date(row.spotify_expires_at).getTime() > Date.now() + 60_000;
  if (stillValid) return row.spotify_access_token;

  if (!row.spotify_refresh_token) throw new Error("Spotify isn't connected yet.");

  const t = await spotifyToken({
    grant_type: "refresh_token",
    refresh_token: row.spotify_refresh_token,
  });

  const patch: Record<string, unknown> = {
    spotify_access_token: t.access_token,
    spotify_expires_at: new Date(Date.now() + (t.expires_in || 3600) * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  };
  // Spotify may hand back a rotated refresh token; if it does, keep it.
  if (t.refresh_token) patch.spotify_refresh_token = t.refresh_token;

  await admin.from("music_settings").update(patch).eq("user_id", row.user_id);
  row.spotify_access_token = t.access_token;
  return t.access_token;
}

async function sp(token: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${SPOTIFY_API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  if (res.status === 429) {
    throw new Error(`Spotify rate-limited us. Retry in ${res.headers.get("Retry-After") || "a few"}s.`);
  }
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 200);
    throw new Error(`Spotify ${res.status} — ${detail}`);
  }
  return res.status === 204 ? null : await res.json();
}

// ── Spotify: resolve a find into track URIs ────────────────────────────────
// Artist-only → search tracks by artist. Spotify REMOVED /artists/{id}/top-tracks
// for Development Mode apps (Feb 2026), and stripped `popularity` from track
// objects, so relevance-ranked search is the best available stand-in for "top
// tracks". Search `limit` is capped at 10 as of the same change.
async function resolveArtist(token: string, artist: string) {
  const q = encodeURIComponent(`artist:"${artist}"`);
  const r = await sp(token, `/search?q=${q}&type=track&limit=10`);
  const tracks = r?.tracks?.items || [];
  if (!tracks.length) return null;

  // Keep only tracks actually credited to this artist — a bare relevance search
  // will happily return a different band's song that name-drops them.
  const wanted = artist.toLowerCase();
  const own = tracks.filter((t: any) =>
    (t.artists || []).some((a: any) => a.name.toLowerCase() === wanted)
  );
  const picked = (own.length ? own : tracks).slice(0, TOP_TRACKS_PER_ARTIST);
  if (!picked.length) return null;

  return {
    uris: picked.map((t: any) => t.uri),
    artistId: picked[0].artists?.[0]?.id || null,
    matched: picked[0].artists?.[0]?.name || artist,
  };
}

// Album named → the whole tracklist. This endpoint survived the cull.
async function resolveAlbum(token: string, artist: string, album: string) {
  const q = encodeURIComponent(`album:"${album}" artist:"${artist}"`);
  const r = await sp(token, `/search?q=${q}&type=album&limit=10`);
  const hit = (r?.albums?.items || [])[0];
  if (!hit) return null;

  // Album tracks paginate at 50 — a box set needs more than one page.
  const uris: string[] = [];
  let offset = 0;
  for (;;) {
    const page = await sp(token, `/albums/${hit.id}/tracks?limit=50&offset=${offset}`);
    const items = page?.items || [];
    uris.push(...items.map((t: any) => t.uri));
    if (items.length < 50) break;
    offset += 50;
  }
  if (!uris.length) return null;

  return {
    uris,
    albumId: hit.id,
    artistId: hit.artists?.[0]?.id || null,
    matched: `${hit.artists?.[0]?.name || artist} — ${hit.name}`,
  };
}

async function ensurePlaylist(token: string, row: Record<string, any>): Promise<string> {
  if (row.playlist_id) return row.playlist_id;
  // Create endpoint moved to /me/playlists — /users/{id}/playlists now 403s.
  const p = await sp(token, "/me/playlists", {
    method: "POST",
    body: JSON.stringify({
      name: row.playlist_name || "Crate — bands to check out",
      public: false,
      description: "Auto-filled from posts I screenshotted. Built by Crate.",
    }),
  });
  await admin.from("music_settings").update({ playlist_id: p.id }).eq("user_id", row.user_id);
  row.playlist_id = p.id;
  return p.id;
}

async function addTracks(token: string, playlistId: string, uris: string[]) {
  // Path moved to /items (from /tracks); still capped at 100 URIs per call.
  for (let i = 0; i < uris.length; i += 100) {
    await sp(token, `/playlists/${playlistId}/items`, {
      method: "POST",
      body: JSON.stringify({ uris: uris.slice(i, i + 100) }),
    });
  }
}

// ── Auth helpers ───────────────────────────────────────────────────────────
async function userFromJWT(req: Request): Promise<string> {
  const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data?.user) throw new Error("Not signed in.");
  return data.user.id;
}

async function settingsFor(userId: string) {
  const { data } = await admin.from("music_settings").select("*").eq("user_id", userId).single();
  if (data) return data;
  const key = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
  const { data: created, error } = await admin
    .from("music_settings")
    .insert({ user_id: userId, ingest_key: key })
    .select("*")
    .single();
  if (error) throw error;
  return created;
}

// ── Handler ────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!ANTHROPIC_API_KEY) return json({ error: "ANTHROPIC_API_KEY not set" }, 500);
  if (!SPOTIFY_CLIENT_ID || !SPOTIFY_CLIENT_SECRET) {
    return json({ error: "Spotify client credentials not set" }, 500);
  }

  let body: Record<string, any>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  try {
    // ---- status -----------------------------------------------------------
    if (body.mode === "status") {
      const row = await settingsFor(await userFromJWT(req));
      return json({
        connected: !!row.spotify_refresh_token,
        ingest_key: row.ingest_key,
        playlist_id: row.playlist_id,
        playlist_url: row.playlist_id
          ? `https://open.spotify.com/playlist/${row.playlist_id}`
          : null,
      });
    }

    // ---- auth_url ---------------------------------------------------------
    if (body.mode === "auth_url") {
      const userId = await userFromJWT(req);
      await settingsFor(userId);
      const url =
        "https://accounts.spotify.com/authorize?" +
        new URLSearchParams({
          client_id: SPOTIFY_CLIENT_ID,
          response_type: "code",
          redirect_uri: REDIRECT_URI,
          scope: SCOPES,
          state: userId,
        });
      return json({ url });
    }

    // ---- auth_code --------------------------------------------------------
    if (body.mode === "auth_code") {
      const userId = await userFromJWT(req);
      if (body.state !== userId) return json({ error: "State mismatch." }, 400);

      const t = await spotifyToken({
        grant_type: "authorization_code",
        code: String(body.code || ""),
        redirect_uri: REDIRECT_URI,
      });
      if (!t.refresh_token) return json({ error: "Spotify returned no refresh token." }, 502);

      await admin.from("music_settings").update({
        spotify_refresh_token: t.refresh_token,
        spotify_access_token: t.access_token,
        spotify_expires_at: new Date(Date.now() + (t.expires_in || 3600) * 1000).toISOString(),
        updated_at: new Date().toISOString(),
      }).eq("user_id", userId);

      return json({ ok: true });
    }

    // ---- ingest -----------------------------------------------------------
    if (body.mode === "ingest") {
      // The Shortcut sends the ingest key; the web page sends a session JWT.
      let row: Record<string, any>;
      const key = req.headers.get("x-ingest-key") || body.ingest_key;
      if (key) {
        const { data } = await admin
          .from("music_settings").select("*").eq("ingest_key", String(key)).single();
        if (!data) return json({ error: "Bad ingest key." }, 401);
        row = data;
      } else {
        row = await settingsFor(await userFromJWT(req));
      }
      if (!row.spotify_refresh_token) {
        return json({ error: "Spotify isn't connected. Open the Crate page and connect." }, 400);
      }

      // Build the Claude message: one or more screenshots, and/or text.
      const images: string[] = body.images || (body.image ? [body.image] : []);
      const mediaType = String(body.media_type || "image/jpeg");
      const text = String(body.text || "").trim();
      if (!images.length && !text) return json({ error: "Send an image or some text." }, 400);

      // A full ingest is slow — Claude reads the image, then every artist costs
      // a Spotify search and a tracklist fetch. 30–60s is normal. An iOS
      // share-sheet extension will not wait that long; it drops the socket and
      // reports "the network connection was lost", even though the work was
      // fine. So the Shortcut gets an instant 202 and we finish the job after
      // the response has already been sent. The web page still waits (it wants
      // the added/skipped list to render), which it can afford to.
      if (key && body.wait !== true) {
        // deno-lint-ignore no-explicit-any
        (globalThis as any).EdgeRuntime?.waitUntil(
          runIngest(row, images, mediaType, text).catch((e) =>
            console.error("background ingest failed:", (e as Error).message)
          )
        );
        return json({ ok: true, queued: true, note: "Sent to the crate." }, 202);
      }

      return json(await runIngest(row, images, mediaType, text));
    }

    return json({ error: `Unknown mode: ${body.mode}` }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || "Something went wrong." }, 502);
  }
});

// ── The actual work: image/text → Claude → Spotify → playlist ───────────────
// Split out of the handler so it can either be awaited (web page) or run past
// the end of the response via EdgeRuntime.waitUntil (iOS Shortcut).
async function runIngest(
  row: Record<string, any>,
  images: string[],
  mediaType: string,
  text: string,
) {
  const content: unknown[] = images.map((b64) => ({
    type: "image",
    source: { type: "base64", media_type: sniffMedia(b64, mediaType), data: b64 },
  }));
  content.push({
    type: "text",
    text: text ? `${EXTRACT_PROMPT}\n\nPost text:\n${text}` : EXTRACT_PROMPT,
  });

  const { finds, unidentified, context } = await extractFinds(content);
  const source = images.length ? "screenshot" : "text";

  // Anything the first pass couldn't name gets a second, slower look — this
  // time with web search, because these posts are about new releases and the
  // press for them exists. Only worth doing when there's an image to match
  // against and something actually went unnamed.
  const stillUnknown = [...unidentified];
  const rescued: Find[] = [];

  if (unidentified.length && images.length) {
    const found = await identifyCovers(images, mediaType, unidentified, context, finds);
    // Walk highest-index-first so the splices don't shift the ones behind them.
    for (const c of found.sort((a, b) => b.index - a.index)) {
      const i = c.index - 1;
      if (i < 0 || i >= stillUnknown.length) continue;
      stillUnknown.splice(i, 1);
      rescued.push({ artist: c.artist, album: c.album, confidence: "guess" });
    }
  }

  const all = [...finds, ...rescued];

  // A cover we still can't name becomes a row in the crate, not just a toast.
  // The toast only exists on the web path and only until the next render; the
  // Shortcut never sees it. A row survives both, and the description is often
  // enough for a human to go "that's Joyce Manor" and add it by name.
  for (const desc of stillUnknown) {
    await admin.from("music_finds").insert({
      user_id: row.user_id,
      artist: desc,
      album: null,
      source,
      status: "unidentified",
      note: "Couldn't name this cover — add the band by name if you know it.",
    });   // a duplicate description just bounces off the dedupe index
  }

  const missed = stillUnknown.length
    ? `Couldn't identify ${stillUnknown.length} cover${stillUnknown.length === 1 ? "" : "s"} — see the crate.`
    : null;

  if (!all.length) {
    return { added: [], skipped: [], note: missed || "No artists found in that." };
  }

  const token = await accessTokenFor(row);
  const playlistId = await ensurePlaylist(token, row);

  const added: unknown[] = [];
  const skipped: unknown[] = [];

  for (const f of all) {
    const artist = f.artist.trim();
    const album = f.album?.trim() || null;
    const guessed = f.confidence === "guess";

    // Dedupe first — a bare insert lets the unique index reject repeats
    // without us having to query for them.
    const claim = await admin.from("music_finds").insert({
      user_id: row.user_id, artist, album, source, status: "pending",
      note: guessed ? "Cover had no text — identified from the artwork." : null,
    }).select("id").single();

    if (claim.error) {
      skipped.push({ artist, album, why: "already in the crate" });
      continue;
    }

    try {
      const hit = album
        ? await resolveAlbum(token, artist, album)
        : await resolveArtist(token, artist);

      if (!hit) {
        await admin.from("music_finds").update({
          status: "no_match", note: "Spotify had no match.",
        }).eq("id", claim.data.id);
        skipped.push({ artist, album, why: "no Spotify match" });
        continue;
      }

      await addTracks(token, playlistId, hit.uris);
      await admin.from("music_finds").update({
        status: "added",
        tracks_added: hit.uris.length,
        matched_name: hit.matched,
        spotify_artist_id: (hit as any).artistId || null,
        spotify_album_id: (hit as any).albumId || null,
      }).eq("id", claim.data.id);

      added.push({ artist, album, matched: hit.matched, tracks: hit.uris.length });
    } catch (e) {
      await admin.from("music_finds").update({
        status: "error", note: (e as Error).message.slice(0, 300),
      }).eq("id", claim.data.id);
      skipped.push({ artist, album, why: (e as Error).message });
    }
  }

  return {
    added,
    skipped,
    note: missed,
    playlist_url: `https://open.spotify.com/playlist/${playlistId}`,
  };
}
