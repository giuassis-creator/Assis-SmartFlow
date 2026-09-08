#!/usr/bin/env python3
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

N8N = os.getenv("N8N_INTERNAL_URL", "http://n8n:5678").rstrip("/")
TOKEN = os.environ.get("INTERNAL_AGENT_TOKEN", "")
CALENDAR_ID = os.environ.get("CALENDAR_ID", "primary")
TZ = ZoneInfo(os.environ.get("GENERIC_TIMEZONE", "America/Sao_Paulo"))


def fail(message):
    raise RuntimeError(message)


def post(path, payload, token=TOKEN, expect_success=True, timeout=90):
    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["x-assis-internal-token"] = token
    req = urllib.request.Request(f"{N8N}{path}", data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
            status = response.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        status = exc.code
        if expect_success:
            fail(f"POST {path} failed with HTTP {status}: {raw[:1200]}")
        return status, raw, None
    except Exception as exc:
        if expect_success:
            fail(f"POST {path} failed: {exc}")
        return 0, str(exc), None

    if not expect_success:
        fail(f"POST {path} unexpectedly succeeded with HTTP {status}: {raw[:1200]}")

    try:
        parsed = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        parsed = {"raw": raw}
    return status, raw, parsed


def find_value(value, key):
    if isinstance(value, dict):
        if value.get(key):
            return value[key]
        for child in value.values():
            found = find_value(child, key)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_value(child, key)
            if found:
                return found
    return None


def gateway(tool, arguments, organization_id, idempotency_key=None, confirmed=False, expect_success=True):
    payload = {
        "agent_id": "calendar.agent",
        "organization_id": organization_id,
        "confirmed": confirmed,
        "trace_id": f"calendar-smoke-{uuid.uuid4()}",
        "tool_call": {"name": tool, "arguments": arguments},
    }
    if idempotency_key:
        payload["idempotency_key"] = idempotency_key
    return post("/webhook/assis/internal/tool/execute", payload, expect_success=expect_success)


def pg_connect():
    return psycopg.connect(
        host=os.environ.get("POSTGRES_HOST", "postgres"),
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    )


def create_smoke_organization():
    marker = uuid.uuid4().hex
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO organizations(slug,name,config) VALUES(%s,%s,%s::jsonb) RETURNING id::text",
                (f"calendar-smoke-{marker}", "Assis SmartFlow Calendar Smoke", json.dumps({"smoke_test": True})),
            )
            organization_id = cur.fetchone()[0]
        conn.commit()
    return organization_id


def cleanup_smoke_organization(organization_id):
    if not organization_id:
        return
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM tool_idempotency WHERE organization_id=%s::uuid", (organization_id,))
            cur.execute("DELETE FROM organizations WHERE id=%s::uuid", (organization_id,))
        conn.commit()


def main():
    if not TOKEN or TOKEN.startswith("CHANGE_ME"):
        fail("INTERNAL_AGENT_TOKEN is missing or still a placeholder.")

    organization_id = create_smoke_organization()
    event_id = None
    cancelled = False

    try:
        now = datetime.now(TZ)
        start = (now + timedelta(days=2)).replace(minute=0, second=0, microsecond=0)
        end = start + timedelta(minutes=20)
        moved_start = start + timedelta(minutes=40)
        moved_end = moved_start + timedelta(minutes=20)

        print("Calendar auth negative path...")
        post(
            "/webhook/assis/internal/calendar/availability",
            {
                "organization_id": organization_id,
                "calendar_id": CALENDAR_ID,
                "time_min": start.isoformat(),
                "time_max": (start + timedelta(hours=2)).isoformat(),
            },
            token="invalid-calendar-smoke-token",
            expect_success=False,
        )

        print("Calendar availability through Policy Gateway...")
        gateway(
            "calendar.availability",
            {
                "calendar_id": CALENDAR_ID,
                "time_min": start.isoformat(),
                "time_max": (start + timedelta(hours=2)).isoformat(),
            },
            organization_id,
        )

        print("Calendar write rejects missing confirmation...")
        gateway(
            "calendar.book",
            {
                "calendar_id": CALENDAR_ID,
                "start": start.isoformat(),
                "end": end.isoformat(),
                "summary": "[Assis SmartFlow QA] confirmation-negative",
            },
            organization_id,
            idempotency_key=f"qa-negative-{uuid.uuid4()}",
            confirmed=False,
            expect_success=False,
        )

        book_key = f"qa-book-{uuid.uuid4()}"
        print("Calendar create through Policy Gateway...")
        _, _, created = gateway(
            "calendar.book",
            {
                "calendar_id": CALENDAR_ID,
                "start": start.isoformat(),
                "end": end.isoformat(),
                "summary": "[Assis SmartFlow QA] temporary runtime smoke",
                "description": "Temporary automated homologation event; should be removed by the same smoke test.",
            },
            organization_id,
            idempotency_key=book_key,
            confirmed=True,
        )
        event_id = find_value(created, "event_id") or find_value(created, "id")
        if not event_id:
            fail(f"Calendar create succeeded but no event_id was returned: {created}")

        print("Calendar durable idempotency rejects duplicate create...")
        gateway(
            "calendar.book",
            {
                "calendar_id": CALENDAR_ID,
                "start": start.isoformat(),
                "end": end.isoformat(),
                "summary": "[Assis SmartFlow QA] duplicate must not create",
            },
            organization_id,
            idempotency_key=book_key,
            confirmed=True,
            expect_success=False,
        )

        print("Calendar reschedule through Policy Gateway...")
        gateway(
            "calendar.reschedule",
            {
                "calendar_id": CALENDAR_ID,
                "event_id": event_id,
                "start": moved_start.isoformat(),
                "end": moved_end.isoformat(),
            },
            organization_id,
            idempotency_key=f"qa-reschedule-{uuid.uuid4()}",
            confirmed=True,
        )

        print("Calendar cancel through Policy Gateway...")
        gateway(
            "calendar.cancel",
            {"calendar_id": CALENDAR_ID, "event_id": event_id},
            organization_id,
            idempotency_key=f"qa-cancel-{uuid.uuid4()}",
            confirmed=True,
        )
        cancelled = True
        print("PASS: Google Calendar availability, auth rejection, confirmation gate, durable duplicate prevention, create, reschedule and cancel are operational.")
    finally:
        if event_id and not cancelled:
            try:
                gateway(
                    "calendar.cancel",
                    {"calendar_id": CALENDAR_ID, "event_id": event_id},
                    organization_id,
                    idempotency_key=f"qa-cleanup-{uuid.uuid4()}",
                    confirmed=True,
                )
                print("Cleanup: temporary event cancelled after an earlier failure.")
            except Exception as cleanup_exc:
                print(f"WARNING: automatic Calendar cleanup failed for event {event_id}: {cleanup_exc}", file=sys.stderr)
        cleanup_smoke_organization(organization_id)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
