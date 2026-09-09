import json
import os
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import psycopg

BASE = os.getenv('N8N_INTERNAL_URL', 'http://n8n:5678').rstrip('/')
TOKEN = os.getenv('INTERNAL_AGENT_TOKEN', '')
PG_HOST = os.getenv('POSTGRES_HOST', 'postgres')
PG_DB = os.getenv('POSTGRES_DB', '')
PG_USER = os.getenv('POSTGRES_USER', '')
PG_PASSWORD = os.getenv('POSTGRES_PASSWORD', '')


def log(message):
    print(message, flush=True)


def require(cond, message):
    if not cond:
        raise RuntimeError(message)


def post(path, payload, timeout=180):
    req = Request(
        BASE + path,
        data=json.dumps(payload).encode('utf-8'),
        headers={
            'Content-Type': 'application/json',
            'x-assis-internal-token': TOKEN,
        },
        method='POST',
    )
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode('utf-8')
            return resp.status, json.loads(raw) if raw else None
    except HTTPError as exc:
        raw = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f'{path} HTTP {exc.code}: {raw}') from exc
    except URLError as exc:
        raise RuntimeError(f'{path} unreachable: {exc}') from exc


def wait_for_registered_webhook(path, timeout=120):
    deadline = time.time() + timeout
    attempt = 0
    last_error = None
    while time.time() < deadline:
        attempt += 1
        req = Request(
            BASE + path,
            data=b'{}',
            headers={
                'Content-Type': 'application/json',
                'x-assis-internal-token': 'invalid-readiness-probe',
            },
            method='POST',
        )
        try:
            with urlopen(req, timeout=10) as resp:
                resp.read()
                log(f'Webhook {path} registered after {attempt} attempt(s).')
                return
        except HTTPError as exc:
            body = exc.read().decode('utf-8', errors='replace')
            if exc.code != 404 or 'not registered' not in body.lower():
                log(f'Webhook {path} registered after {attempt} attempt(s).')
                return
            last_error = f'HTTP {exc.code}: {body}'
        except URLError as exc:
            last_error = str(exc)
        time.sleep(2)
    raise RuntimeError(f'Webhook {path} was not registered within {timeout}s: {last_error}')


def pg_connect():
    return psycopg.connect(host=PG_HOST, dbname=PG_DB, user=PG_USER, password=PG_PASSWORD)


def create_fixture(marker):
    slug = f'smoke-auto-memory-{marker.lower()}'
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                'INSERT INTO organizations(slug,name,config) VALUES(%s,%s,%s::jsonb) RETURNING id',
                (slug, 'Assis SmartFlow Auto Memory Smoke', json.dumps({'smoke_test': True})),
            )
            org_id = str(cur.fetchone()[0])
            cur.execute(
                'INSERT INTO contacts(organization_id,external_id,name,metadata) VALUES(%s::uuid,%s,%s,%s::jsonb) RETURNING id',
                (org_id, f'contact-{marker.lower()}', 'Auto Memory Smoke', json.dumps({'smoke_test': True})),
            )
            contact_id = str(cur.fetchone()[0])
            conversations = []
            for idx in (1, 2):
                cur.execute(
                    'INSERT INTO conversations(organization_id,contact_id,channel,external_id,context,last_message_at) VALUES(%s::uuid,%s::uuid,%s,%s,%s::jsonb,now()) RETURNING id',
                    (org_id, contact_id, 'smoke', f'auto-memory-{marker.lower()}-{idx}', json.dumps({'smoke_test': True})),
                )
                conversations.append(str(cur.fetchone()[0]))
        conn.commit()
    return org_id, contact_id, conversations[0], conversations[1]


def cleanup(org_id):
    if not org_id:
        return
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute('DELETE FROM organizations WHERE id=%s::uuid', (org_id,))
        conn.commit()


def count_long_term(contact_id):
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM long_term_memory WHERE contact_id=%s::uuid', (contact_id,))
            return int(cur.fetchone()[0])


def main():
    require(TOKEN, 'INTERNAL_AGENT_TOKEN unavailable')

    log('Waiting for automatic-memory production webhooks...')
    for path in (
        '/webhook/internal/context',
        '/webhook/internal/memory/write',
        '/webhook/internal/memory/auto-capture',
        '/webhook/assis/v1/maya/orchestrate',
    ):
        wait_for_registered_webhook(path)

    marker = f'AUTOMEM_{int(time.time())}'
    org_id = None
    stage = 'fixture'
    try:
        org_id, contact_id, first_conversation, second_conversation = create_fixture(marker)

        stage = 'restricted prefilter'
        log('Restricted explicit secret is not captured...')
        before = count_long_term(contact_id)
        status, blocked = post('/webhook/internal/memory/auto-capture', {
            'conversation_id': first_conversation,
            'text': f'Guarde minha senha como {marker}.',
        })
        require(status == 200 and isinstance(blocked, dict), f'Unexpected blocked capture response: {blocked!r}')
        require(blocked.get('captured') is False, f'Restricted secret was captured: {blocked!r}')
        require(count_long_term(contact_id) == before, 'Restricted secret changed long-term memory')

        stage = 'long-term-only memory write'
        log('Validating long-term-only Memory Write before automatic classification...')
        probe_key = f'probe_{marker.lower()}'
        status, probe = post('/webhook/internal/memory/write', {
            'conversation_id': first_conversation,
            'write_short_term': False,
            'long_term': True,
            'category': 'preference',
            'memory_key': probe_key,
            'memory_value': {'value': marker, 'source': 'runtime_probe'},
            'confidence': 1,
        })
        require(status == 200 and isinstance(probe, dict), f'Unexpected long-term-only write response: {probe!r}')
        require(bool(probe.get('long_term')), f'Long-term-only write did not persist: {probe!r}')
        with pg_connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    'DELETE FROM long_term_memory WHERE organization_id=%s::uuid AND contact_id=%s::uuid AND memory_key=%s',
                    (org_id, contact_id, f'preference:{probe_key}'),
                )
            conn.commit()

        stage = 'direct automatic capture'
        log('Validating automatic classifier and persistence directly...')
        statement = f'Guarde como preferência que meu código de contato preferido é {marker}.'
        status, direct = post('/webhook/internal/memory/auto-capture', {
            'conversation_id': first_conversation,
            'text': statement,
        }, timeout=300)
        require(status == 200 and isinstance(direct, dict), f'Unexpected direct automatic capture response: {direct!r}')
        require(direct.get('captured') is True, f'Direct automatic capture did not store the explicit preference: {direct!r}')

        # Remove the direct probe so the following Maya turn must prove its own integrated capture.
        with pg_connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    'DELETE FROM long_term_memory WHERE organization_id=%s::uuid AND contact_id=%s::uuid',
                    (org_id, contact_id),
                )
            conn.commit()

        stage = 'Maya integrated capture'
        log('Maya automatically captures an explicit durable preference...')
        status, first = post('/webhook/assis/v1/maya/orchestrate', {
            'text': statement,
            'conversation_id': first_conversation,
            'trace_id': f'{marker}-capture',
        }, timeout=360)
        require(status == 200 and isinstance(first, dict), f'Unexpected Maya capture response: {first!r}')
        require(first.get('context_loaded') is True, f'Maya did not load first conversation: {first!r}')
        require(first.get('long_term_memory_captured') is True, f'Maya did not report automatic durable capture: {first!r}')

        with pg_connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT memory_key,memory_value->>'value' FROM long_term_memory WHERE organization_id=%s::uuid AND contact_id=%s::uuid ORDER BY updated_at DESC LIMIT 1",
                    (org_id, contact_id),
                )
                row = cur.fetchone()
                require(row is not None, 'Automatic durable memory row not found')
                require(marker.casefold() in str(row[1] or '').casefold(), f'Automatic durable value does not preserve user evidence: {row!r}')

        stage = 'cross-conversation context'
        log('A new conversation loads and recalls the automatically captured fact...')
        status, context = post('/webhook/internal/context', {
            'conversation_id': second_conversation,
            'max_messages': 20,
        })
        require(status == 200 and isinstance(context, dict), f'Unexpected second-conversation context: {context!r}')
        require(marker.casefold() in str(context.get('summary') or '').casefold(), f'Automatic durable fact missing from second-conversation context: {context!r}')

        stage = 'Maya cross-conversation recall'
        status, second = post('/webhook/assis/v1/maya/orchestrate', {
            'text': 'Qual é meu código de contato preferido? Responda apenas com o código.',
            'conversation_id': second_conversation,
            'trace_id': f'{marker}-recall',
        }, timeout=360)
        require(status == 200 and isinstance(second, dict), f'Unexpected Maya recall response: {second!r}')
        require(second.get('context_loaded') is True, f'Maya did not load second conversation: {second!r}')
        require(marker.casefold() in str(second.get('response') or '').casefold(), f'Maya did not recall automatically captured durable fact: {second!r}')

        log('PASS: Maya automatically captures explicit durable facts, blocks restricted data, and recalls accepted facts across conversations.')
    except Exception as exc:
        raise RuntimeError(f'AUTO_MEMORY_STAGE={stage}: {exc}') from exc
    finally:
        cleanup(org_id)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL: {exc}', file=sys.stderr, flush=True)
        sys.exit(1)
