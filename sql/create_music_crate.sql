-- ============================================================================
-- Crate — "bands to check out" pipeline
--
-- Screenshot a music post (TikTok, IG, a blog's "best albums this week") →
-- share it to an iOS Shortcut → Claude reads the artists/albums off the image
-- → Spotify resolves them → tracks land in a playlist.
--
-- Rule: artist-only  → that artist's top 3 tracks (via search; Spotify removed
--                      the top-tracks endpoint for Dev Mode apps in Feb 2026)
--       album named  → the album's full tracklist
--
-- Run in the Supabase SQL editor.
-- ============================================================================

-- ── Per-user settings: Spotify tokens + the Shortcut's ingest key ───────────
-- The ingest key is what the iOS Shortcut sends instead of a Supabase JWT
-- (magic-link sessions expire; a long-lived key in the Shortcut does not).
-- It maps back to a user_id, so the edge function knows whose playlist to fill.
create table if not exists public.music_settings (
  user_id                uuid primary key references auth.users(id) on delete cascade,
  ingest_key             text unique not null,
  spotify_refresh_token  text,
  spotify_access_token   text,
  spotify_expires_at     timestamptz,
  playlist_id            text,
  playlist_name          text not null default 'Crate — bands to check out',
  updated_at             timestamptz not null default now()
);

-- ── Every artist/album we've pulled in ─────────────────────────────────────
create table if not exists public.music_finds (
  id                bigint generated always as identity primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  artist            text not null,
  album             text,                -- null = artist highlight, not an album rec
  source            text,                -- screenshot | url | text
  spotify_artist_id text,
  spotify_album_id  text,
  matched_name      text,                -- what Spotify actually matched (for spotting mismatches)
  tracks_added      integer not null default 0,
  status            text not null default 'pending',  -- added | no_match | error
  note              text,
  created_at        timestamptz not null default now()
);

-- Dedupe: the same band fed to you five times shouldn't land five times.
-- Artist-only and artist+album are distinct rows on purpose — a band you
-- sampled can later get its album added in full.
create unique index if not exists idx_music_finds_dedupe
  on public.music_finds (user_id, lower(artist), coalesce(lower(album), ''));

create index if not exists idx_music_finds_user_created
  on public.music_finds (user_id, created_at desc);

-- ── RLS ────────────────────────────────────────────────────────────────────
alter table public.music_settings enable row level security;
alter table public.music_finds    enable row level security;

-- Finds: you see and manage your own.
drop policy if exists "own finds" on public.music_finds;
create policy "own finds" on public.music_finds
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Settings: deliberately NO policy for the anon/authenticated roles, so the
-- Spotify refresh token is unreadable from the browser. The edge function
-- reaches it with the service-role key, which bypasses RLS. The web page asks
-- the edge function for connection status instead of reading this table.
