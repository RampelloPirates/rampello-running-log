#!/usr/bin/env python3
"""
Run this ONCE locally to create a Garmin auth token for the sync worker.

It logs into Garmin (prompting for your MFA code if enabled), saves the OAuth
tokens, and prints a single base64 string. Put that string into the GitHub
secret GARMIN_TOKENS_BASE64. The worker then logs in with the token — no
password or MFA needed on the schedule, and the token lasts ~1 year.

    pip install garminconnect
    python gen_token.py
"""
import base64
import getpass
import io
import os
import sys
import tempfile
import zipfile

from garminconnect import Garmin


def main():
    email = input("Garmin email: ").strip()
    password = getpass.getpass("Garmin password: ")
    print("Logging in (enter your MFA code if prompted)…")

    tokendir = tempfile.mkdtemp()
    try:
        garmin = Garmin(email, password)
        garmin.login()  # prompts for MFA code interactively if the account requires it
        garmin.garth.dump(tokendir)
    except Exception as e:
        print("\nLogin / token save failed:")
        print(f"  {e}")
        print("\nIf you saw a 429 / 'rate limited' message above, Garmin has temporarily")
        print("throttled logins from your IP (not your password). To recover:")
        print("  - Wait ~30-60 min, then run this again ONCE (don't retry rapidly).")
        print("  - Or run it on a different network (e.g. phone hotspot) - it's per-IP.")
        print("  - Make sure libraries are current:")
        print("      python -m pip install --upgrade garminconnect garth")
        sys.exit(1)

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name in os.listdir(tokendir):
            z.write(os.path.join(tokendir, name), name)

    print("\n=== GARMIN_TOKENS_BASE64 (copy everything on the next line) ===\n")
    print(base64.b64encode(buf.getvalue()).decode())
    print("\n=== end ===")


if __name__ == "__main__":
    main()
