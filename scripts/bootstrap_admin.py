#!/usr/bin/env python3
"""One-time admin bootstrap for a JungleChat Supabase project.

What it does (idempotent where possible):
  1. Creates an admin auth user (if the email does not already exist).
  2. Grants that user the admin role (insert into public.admin_roles).

The admin_list_reports schema is owned exclusively by the SQL migrations under
supabase/migrations and MUST NOT be altered by this script. (An older revision
applied a migration that joined the dropped `rooms` table; that step is
intentionally removed — the live function is the 7-column shape defined in
migrations 0001-0313.)

The Supabase Personal Access Token is read from the environment
(SUPABASE_ACCESS_TOKEN) and is NEVER hardcoded or printed back.

Usage:
  SUPABASE_ACCESS_TOKEN=xxx python3 scripts/bootstrap_admin.py \
      --ref ndvdrpmrdifcakjbbbjy \
      --email admin@junglechat.app \
      --password 'strong-password-here'
"""
import argparse
import json
import os
import sys
import urllib.request

API = "https://api.supabase.com/v1"


def _req(token, method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("apikey", token)
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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ref", required=True)
    p.add_argument("--email", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--issuer", default="JungleChat")
    a = p.parse_args()

    token = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if not token:
        sys.exit("SUPABASE_ACCESS_TOKEN not set")

    # 1. Create admin auth user if missing.
    st, body = _req(token, "GET",
                    f"{API}/projects/{a.ref}/auth/users?filter=email.eq.{a.email}")
    existing = body.get("users") if isinstance(body, dict) else None
    if existing:
        uid = existing[0]["id"]
        print(f"[1] admin user already exists: {uid}")
    else:
        st, body = _req(token, "POST",
                        f"{API}/projects/{a.ref}/auth/users",
                        {
                            "email": a.email,
                            "password": a.password,
                            "email_confirm": True,
                            "user_metadata": {"app_meta": a.issuer},
                        })
        if st >= 400:
            sys.exit(f"[1] create user failed HTTP {st}: {body}")
        uid = body.get("id") or (body.get("data") or {}).get("id")
        print(f"[1] created admin user: {uid}")

    # 2. Grant admin role.
    grant = (
        "insert into public.admin_roles (user_id) "
        f"select '{uid}'::uuid "
        "on conflict (user_id) do nothing;"
    )
    st, _ = _req(token, "POST",
                 f"{API}/projects/{a.ref}/database/query",
                 {"query": grant})
    print(f"[2] grant admin_roles -> HTTP {st}")
    print("Done. Sign in at the admin panel with MFA.")


if __name__ == "__main__":
    main()
