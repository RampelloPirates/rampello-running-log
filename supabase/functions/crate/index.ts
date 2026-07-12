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
const REDIRECT_URI = "https://rampello-running-log.vercel.app/music.html";

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
const EXTRACT_PROMPT =
  `You are reading a music recommendation — a social post, a screenshot of one, or a music blog's roundup.

List every musical artist mentioned. For each one:
- "artist": the artist or band name.
- "album": the album title, ONLY if this specific album is what's being recommended. If the post is highlighting the artist generally, or you can't tell which album, use null.

Rules:
- One entry per artist. If a post shows ten album covers, return ten entries.
- Read album-cover art carefully — the artist name and album title are often both printed on the cover, in stylized type.
- Do NOT invent artists. If you can't read a name confidently, leave it out.
- Ignore the poster, the blog, the playlist curator, and any DJ/host — they are not recommendations.
- Ignore UI text (likes, comments, "follow", usernames, hashtags).`;

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
        },
        required: ["artist", "album"],
        additionalProperties: false,
      },
    },
  },
  required: ["finds"],
  additionalProperties: false,
};

type Find = { artist: string; album: string | null };

async function extractFinds(content: unknown): Promise<Find[]> {
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
  return (out.finds || []).filter((f: Find) => f.artist?.trim());
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

      const content: unknown[] = images.map((b64) => ({
        type: "image",
        source: { type: "base64", media_type: mediaType, data: b64 },
      }));
      content.push({
        type: "text",
        text: text ? `${EXTRACT_PROMPT}\n\nPost text:\n${text}` : EXTRACT_PROMPT,
      });

      const finds = await extractFinds(content);
      if (!finds.length) return json({ added: [], skipped: [], note: "No artists found in that." });

      const token = await accessTokenFor(row);
      const playlistId = await ensurePlaylist(token, row);
      const source = images.length ? "screenshot" : "text";

      const added: unknown[] = [];
      const skipped: unknown[] = [];

      for (const f of finds) {
        const artist = f.artist.trim();
        const album = f.album?.trim() || null;

        // Dedupe first — a bare insert lets the unique index reject repeats
        // without us having to query for them.
        const claim = await admin.from("music_finds").insert({
          user_id: row.user_id, artist, album, source, status: "pending",
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

      return json({
        added,
        skipped,
        playlist_url: `https://open.spotify.com/playlist/${playlistId}`,
      });
    }

    return json({ error: `Unknown mode: ${body.mode}` }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || "Something went wrong." }, 502);
  }
});
