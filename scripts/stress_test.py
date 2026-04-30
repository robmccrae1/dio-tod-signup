#!/usr/bin/env python3
"""
Concurrency stress test for the TOD signup RPC.

Proves that the 25-seat cap holds even when many clients race for the
last seat. Without the FOR UPDATE row lock inside register_for_session(),
this test would produce a session with > 25 registrations.

Usage:
  # 1. Run scripts/stress_test_setup.sql in Supabase SQL Editor.
  # 2. Set the service-role key (NOT the publishable key) in your env:
  SUPABASE_SERVICE_ROLE_KEY='ey...' python3 scripts/stress_test.py
  # 3. Run scripts/stress_test_teardown.sql afterwards to clean up.

Approach:
  We don't go through Google OAuth 50 times. Instead, the SQL setup creates
  a privileged stress_register() function that mirrors register_for_session()
  but accepts a synthetic user_id parameter (instead of reading auth.uid()).
  This validates the same FOR UPDATE row lock under contention without the
  complexity of minting 50 OAuth sessions.

Cleanup is automatic at the end of a successful run, but you can also run
this script with --cleanup-only at any time.
"""

import argparse
import asyncio
import os
import sys
import time
import uuid
from collections import Counter

try:
    import httpx
except ImportError:
    sys.stderr.write("Missing dependency. Install with:\n  pip3 install --break-system-packages httpx\n")
    sys.exit(1)

SUPABASE_URL = "https://fnbkuirtpwjockendkqu.supabase.co"
TEST_EMAIL_DOMAIN = "diocesan.school.nz"  # must match settings.email_domain
TEST_PREFIX = "stress-test-"


def fail(msg: str) -> None:
    sys.stderr.write(f"\n[FAIL] {msg}\n")
    sys.exit(1)


def get_service_key() -> str:
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not key:
        fail(
            "Set SUPABASE_SERVICE_ROLE_KEY in your environment. Find it in:\n"
            "  Supabase Dashboard → Project Settings → API → service_role key.\n"
            "Run as:  SUPABASE_SERVICE_ROLE_KEY='ey...' python3 scripts/stress_test.py"
        )
    return key


async def stress_call(client: httpx.AsyncClient, service_key: str, target_session_id: str, i: int) -> str:
    synthetic_uid = str(uuid.uuid4())
    synthetic_email = f"{TEST_PREFIX}{i}@{TEST_EMAIL_DOMAIN}"
    r = await client.post(
        f"{SUPABASE_URL}/rest/v1/rpc/stress_register",
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
        },
        json={
            "p_session_id": target_session_id,
            "p_user_id": synthetic_uid,
            "p_user_email": synthetic_email,
        },
        timeout=30.0,
    )
    try:
        data = r.json()
        if isinstance(data, dict) and data.get("ok"):
            return "ok"
        return data.get("error", f"http_{r.status_code}") if isinstance(data, dict) else f"http_{r.status_code}"
    except Exception:
        return f"http_{r.status_code}"


async def get_target_session_id(client: httpx.AsyncClient, service_key: str) -> str:
    """Pick the rob-toolkit / slot 1 session as our target."""
    r = await client.get(
        f"{SUPABASE_URL}/rest/v1/sessions?workshop_id=eq.rob-toolkit&slot_id=eq.1&select=id",
        headers={"apikey": service_key, "Authorization": f"Bearer {service_key}"},
    )
    if r.status_code != 200 or not r.json():
        fail(f"Could not fetch test session: {r.status_code} {r.text}")
    return r.json()[0]["id"]


async def cleanup(client: httpx.AsyncClient, service_key: str) -> int:
    """Delete all registrations made by the stress test."""
    r = await client.delete(
        f"{SUPABASE_URL}/rest/v1/registrations?user_email=like.{TEST_PREFIX}*",
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Prefer": "return=representation",
        },
    )
    if r.status_code not in (200, 204):
        fail(f"Cleanup failed: {r.status_code} {r.text}")
    deleted = r.json() if r.text else []
    return len(deleted) if isinstance(deleted, list) else 0


async def count_registrations_for(client: httpx.AsyncClient, service_key: str, session_id: str) -> int:
    r = await client.get(
        f"{SUPABASE_URL}/rest/v1/registrations?session_id=eq.{session_id}&select=user_id",
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Prefer": "count=exact",
        },
    )
    return int(r.headers.get("content-range", "0/0").split("/")[1] or 0)


async def main_async(args):
    service_key = get_service_key()

    async with httpx.AsyncClient() as client:
        if args.cleanup_only:
            n = await cleanup(client, service_key)
            print(f"Cleaned up {n} test registrations.")
            return

        target = await get_target_session_id(client, service_key)
        print(f"Target session: rob-toolkit / slot 1 → {target}")
        print(f"Capacity: 25. Firing {args.n} concurrent register calls…\n")

        await cleanup(client, service_key)  # pre-clean

        t0 = time.perf_counter()
        results = Counter(
            await asyncio.gather(*[stress_call(client, service_key, target, i) for i in range(args.n)])
        )
        elapsed = time.perf_counter() - t0

        final_count = await count_registrations_for(client, service_key, target)

        print(f"Elapsed: {elapsed:.2f}s\n")
        print("Results breakdown:")
        for outcome, count in results.most_common():
            print(f"  {outcome:30s} {count}")
        print(f"\nFinal registration count for that session: {final_count}")

        n = await cleanup(client, service_key)
        print(f"Cleaned up {n} test registrations.\n")

        if final_count > 25:
            fail(f"CAP VIOLATED: expected ≤ 25, got {final_count}")
        if results["ok"] != min(args.n, 25):
            fail(f"Expected exactly {min(args.n, 25)} successes, got {results['ok']}")
        print("✅ PASS — cap held under concurrent load.")


def parse_args():
    p = argparse.ArgumentParser(description="Stress-test the TOD register_for_session RPC.")
    p.add_argument("-n", type=int, default=50, help="number of concurrent clients (default 50)")
    p.add_argument("--cleanup-only", action="store_true", help="just delete leftover test registrations and exit")
    return p.parse_args()


if __name__ == "__main__":
    asyncio.run(main_async(parse_args()))
