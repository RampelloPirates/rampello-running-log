#!/usr/bin/env python3
"""
Run this ONCE locally to authorize the Strava app and get your refresh token.

    pip install requests
    python strava_auth.py

It asks for your Strava app's Client ID + Client Secret, opens a browser to
authorize, captures the response on http://localhost, exchanges it, and prints
the three values to add as GitHub secrets. The refresh token doesn't expire
(unless you revoke access), so this is a one-time step.

Prereq: in your Strava app settings, set "Authorization Callback Domain" to
    localhost
"""
import http.server
import sys
import urllib.parse
import webbrowser

import requests

PORT = 8721
REDIRECT = f"http://localhost:{PORT}/"


def main():
    client_id = input("Strava Client ID: ").strip()
    client_secret = input("Strava Client Secret: ").strip()
    scope = "read,activity:read_all"
    auth_url = (
        "https://www.strava.com/oauth/authorize"
        f"?client_id={client_id}&response_type=code&redirect_uri={REDIRECT}"
        f"&approval_prompt=force&scope={scope}"
    )

    got = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got["code"] = params.get("code", [None])[0]
            got["error"] = params.get("error", [None])[0]
            got["scope"] = params.get("scope", [None])[0]
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
            "Authorization failed or was denied. Make sure your Strava app's "
            "'Authorization Callback Domain' is exactly: localhost"
        )

    r = requests.post(
        "https://www.strava.com/oauth/token",
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "code": got["code"],
            "grant_type": "authorization_code",
        },
    )
    r.raise_for_status()
    tok = r.json()

    granted = got.get("scope") or ""
    print(f"\nGranted scope: {granted or '(none)'}")
    if "activity:read" not in granted:
        print("\n*** WARNING: the 'activity' permission was NOT granted. ***")
        print("The sync will get 401 on activities. Re-run this script and, on the")
        print("Strava authorize page, CHECK the box to view your activities before")
        print("clicking Authorize.\n")

    print("=== Add these three as GitHub repository secrets ===\n")
    print(f"STRAVA_CLIENT_ID = {client_id}")
    print(f"STRAVA_CLIENT_SECRET = {client_secret}")
    print(f"STRAVA_REFRESH_TOKEN = {tok['refresh_token']}")
    print("\n====================================================")


if __name__ == "__main__":
    main()
