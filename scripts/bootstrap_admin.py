#!/usr/bin/env python3
"""Bootstrap / reset the JungleChat admin account on a Supabase project.

Verified against the 2026 Supabase platform:
  - Auth users MUST be created through the Auth Admin API. Rows inserted
    directly into ``auth.users`` via SQL are invisible to the auth service
    and can never sign in. SQL-written password hashes are ignored too.
  - The platform Management API no longer offers user creation.

What it does:
  1. Finds the auth user by email (creates it, pre-confirmed, if missing).
  2. If the user already exists, resets its password to the one provided,
     so the credentials you pass here are always valid afterwards.
  3. Grants the admin role (insert into public.admin_roles, idempotent).

Needs only the project URL and a secret key (sb_secret_... or the legacy
service_role key) from Supabase dashboard -> Project Settings -> API Keys.
The key is read from the environment and is never hardcoded or printed.

Usage:
  SUPABASE_SECRET_KEY=sb_secret_... python3 scripts/bootstrap_admin.py \
      --url https://your-project.supabase.co \
      --email admin@yourdomain.com \
      --password 'strong-password-here'
"""
import argparse
import json
import os
import sys
import urllib.request


def _req(key, method, url, body=None, prefer=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    if prefer:
        req.add_header("Prefer", prefer)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        try:
            detail = json.loads(detail)
        except Exception:
            pass
        return e.code, detail


def _find_user(key, base, email):
    """List auth users (paginated) and match the email client-side.

    The ``filter`` query parameter is unreliable on the current platform
    (it silently returns an empty list), so we paginate and compare here.
    """
    page = 1
    while True:
        st, body = _req(key, "GET",
                        f"{base}/auth/v1/admin/users?per_page=100&page={page}")
        if st >= 400:
            sys.exit(f"listing users failed HTTP {st}: {body}")
        users = (body or {}).get("users", [])
        for u in users:
            if (u.get("email") or "").lower() == email.lower():
                return u
        if len(users) < 100:
            return None
        page += 1


def main():
    p = argparse.ArgumentParser(
        description="Bootstrap or reset the JungleChat admin account.")
    p.add_argument("--url", required=True,
                   help="Project URL, e.g. https://xyz.supabase.co")
    p.add_argument("--email", required=True)
    p.add_argument("--password", required=True)
    a = p.parse_args()

    key = os.environ.get("SUPABASE_SECRET_KEY")
    if not key:
        sys.exit("SUPABASE_SECRET_KEY not set "
                 "(Supabase dashboard -> Project Settings -> API Keys)")
    base = a.url.rstrip("/")

    existing = _find_user(key, base, a.email)
    if existing:
        uid = existing["id"]
        st, body = _req(key, "PUT", f"{base}/auth/v1/admin/users/{uid}",
                        {"password": a.password})
        if st >= 400:
            sys.exit(f"password reset failed HTTP {st}: {body}")
        print(f"[1] existing user found; password reset: {uid}")
    else:
        st, body = _req(key, "POST", f"{base}/auth/v1/admin/users",
                        {"email": a.email, "password": a.password,
                         "email_confirm": True})
        if st >= 400:
            sys.exit(f"create user failed HTTP {st}: {body}")
        uid = body["id"]
        print(f"[1] admin user created (email confirmed): {uid}")

    st, body = _req(key, "POST", f"{base}/rest/v1/admin_roles",
                    {"user_id": uid}, prefer="resolution=ignore-duplicates")
    if st >= 400:
        sys.exit(f"grant failed HTTP {st}: {body}")
    print("[2] admin role granted (idempotent).")
    print("Done. Sign in at the admin panel; MFA (TOTP) enrollment is "
          "prompted on first login.")


if __name__ == "__main__":
    main()
