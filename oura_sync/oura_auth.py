#!/usr/bin/env python3
"""
Run this ONCE locally to authorize your Oura app and store the tokens.

    pip install -r oura_sync/requirements.txt
    # set the same Supabase app creds the Strava/labs sync use:
    export SUPABASE_URL=https://dprmpgjgjppvdlyxlubr.supabase.co
    export SUPABASE_ANON_KEY=...      # anon key from auth.js
    export APP_EMAIL=...              # your app sign-in email
    export APP_PASSWORD=...
    python oura_sync/oura_auth.py

It asks for your Oura app's Client ID + Client Secret, opens a browser to
authorize, captures the code on http://localhost:8721/, exchanges it for
tokens, and writes everything into the `oura_tokens` table in Supabase. The
daily sync reads from there and refreshes as needed — so, unlike Strava, this
adds NO GitHub secrets.

Oura deprecated personal access tokens (Dec 2025), so OAuth2 is the only path.

Prereqs in your Oura app (https://cloud.ouraring.com/oauth/applications):
  - Redirect URI:  http://localhost:8721/     (must match exactly)
"""
import http.server
import os
import sys
import urllib.parse
import webbrowser
from datetime import datetime, timedelta, timezone

import requests
from supabase import create_client

PORT = 8721
REDIRECT = f"http://localhost:{PORT}/"
AUTHORIZE = "https://cloud.ouraring.com/oauth/authorize"
TOKEN = "https://api.ouraring.com/oauth/token"
# Request the read scopes we use now (daily summaries, HR, personal) plus a few
# we may use later. Over-requesting is harmless for a personal, single-user app.
SCOPE = "email personal daily heartrate workout tag session spo2"


def env(key, required=True):
    v = os.environ.get(key)
    if required and not v:
        sys.exit(f"Missing required env var: {key} (see the header of this file)")
    return v


def main():
    supabase_url = env("SUPABASE_URL")
    supabase_key = env("SUPABASE_ANON_KEY")
    app_email = env("APP_EMAIL")
    app_password = env("APP_PASSWORD")

    client_id = input("Oura Client ID: ").strip()
    client_secret = input("Oura Client Secret: ").strip()

    auth_url = (
        f"{AUTHORIZE}?response_type=code&client_id={client_id}"
        f"&redirect_uri={urllib.parse.quote(REDIRECT, safe='')}"
        f"&scope={urllib.parse.quote(SCOPE)}&state=tally"
    )

    got = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got["code"] = params.get("code", [None])[0]
            got["error"] = params.get("error", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<h2>Done. Close this tab and return to the terminal.</h2>")

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("localhost", PORT), Handler)
    print("\nOpening your browser to authorize. If it doesn't open, paste this URL:\n")
    print(auth_url + "\n")
    webbrowser.open(auth_url)
    while "code" not in got:
        server.handle_request()

    if got.get("error") or not got.get("code"):
        sys.exit(
            "Authorization failed or was denied. Make sure your Oura app's "
            "Redirect URI is exactly: " + REDIRECT
        )

    r = requests.post(TOKEN, data={
        "grant_type": "authorization_code",
        "code": got["code"],
        "redirect_uri": REDIRECT,
        "client_id": client_id,
        "client_secret": client_secret,
    })
    if r.status_code != 200:
        sys.exit(f"Token exchange failed ({r.status_code}): {r.text}")
    tok = r.json()

    expires_at = datetime.now(timezone.utc) + timedelta(seconds=int(tok.get("expires_in", 86400)))

    sb = create_client(supabase_url, supabase_key)
    auth = sb.auth.sign_in_with_password({"email": app_email, "password": app_password})
    sb.postgrest.auth(auth.session.access_token)
    sb.table("oura_tokens").upsert({
        "user_id": auth.user.id,
        "client_id": client_id,
        "client_secret": client_secret,
        "access_token": tok["access_token"],
        "refresh_token": tok.get("refresh_token"),
        "expires_at": expires_at.isoformat(),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }, on_conflict="user_id").execute()

    print("\n✓ Oura connected and tokens stored in Supabase.")
    print("  The daily sync (oura_sync.py) will now keep them refreshed.")
    print("  Run a first pull with:  python oura_sync/oura_sync.py")


if __name__ == "__main__":
    main()
