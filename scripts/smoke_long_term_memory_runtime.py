import json
import os
import sys
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import psycopg

BASE = os.getenv('N8N_INTERNAL_URL', 'http://n8n:5678').rstrip('/')
TOKEN = os.getenv('INTERNAL_AGENT_TOKEN', '')
PG_HOST = os.getenv('POSTGRES_HOST', 'postgres')
PG_DB = os.getenv('POSTGRES_DB', '')
PG_USER = os.getenv('POSTGRES_USER', '')
PG_PASSWORD = os.getenv('POSTGRES_PASSWORD', '')


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


def pg_connect():
    return psycopg.connect(host=PG_HOST, dbname=PG_DB, user=PG_USER, password=PG_PASSWORD)


def create_fixture(marker):
    slug = f'smoke-long-memory-{marker.lower()}'
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                'INSERT INTO organizations(slug,name,config) VALUES(%s,%s,%s::jsonb) RETURNING id',
                (slug, 'Assis SmartFlow Long Memory Smoke', json.dumps({'smoke_test': True})),
            )
            org_id = str(cur.fetchone()[0])
            cur.execute(
                'INSERT INTO contacts(organization_id,external_id,name,metadata) VALUES(%s::uuid,%s,%s,%s::jsonb) RETURNING id',
                (org_id, f'contact-{marker.lower()}', 'Long Memory Smoke', json.dumps({'smoke_test': True})),
            )
            contact_id = str(cur.fetchone()[0])
            conversations = []
            for idx in (1, 2):
                cur.execute(
                    'INSERT INTO conversations(organization_id,contact_id,channel,external_id,context,last_message_at) VALUES(%s::uuid,%s::uuid,%s,%s,%s::jsonb,now()) RETURNING id',
                    (org_id, contact_id, 'smoke', f'long-memory-{marker.lower()}-{idx}', json.dumps({'smoke_test': True})),
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


def main():
    require(TOKEN, 'INTERNAL_AGENT_TOKEN unavailable')
    marker = f'LONGMEM_{int(time.time())}'
    org_id = None
    try:
        org_id, contact_id, first_conversation, second_conversation = create_fixture(marker)

        print('Long-term memory policy rejects denied category...')
        try:
            post('/webhook/internal/memory/write', {
                'conversation_id': first_conversation,
                'summary': '',
                'slots': {},
                'long_term': True,
                'category': 'secret',
                'memory_key': 'should_fail',
                'memory_value': {'value': marker},
            })
        except RuntimeError as exc:
            require('HTTP ' in str(exc), f'Unexpected denied-category failure: {exc}')
        else:
            raise RuntimeError('Denied long-term memory category was accepted')

        print('Persisting durable contact preference from first conversation...')
        status, stored = post('/webhook/internal/memory/write', {
            'conversation_id': first_conversation,
            'summary': f'Primeira conversa de homologação {marker}',
            'slots': {'smoke': True},
            'long_term': True,
            'category': 'preference',
            'memory_key': 'preferred_code',
            'memory_value': {'value': marker},
            'confidence': 1,
        })
        require(status == 200 and isinstance(stored, dict), f'Unexpected memory write response: {stored!r}')
        require(stored.get('long_term'), f'Long-term memory was not persisted: {stored!r}')

        with pg_connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    'SELECT memory_key,memory_value->>\'value\' FROM long_term_memory WHERE organization_id=%s::uuid AND contact_id=%s::uuid',
                    (org_id, contact_id),
                )
                row = cur.fetchone()
                require(row is not None, 'Long-term memory row not found in PostgreSQL')
                require(row[0] == 'preference:preferred_code', f'Unexpected memory key: {row!r}')
                require(row[1] == marker, f'Unexpected memory value: {row!r}')

        print('Loading same contact memory from a different conversation...')
        status, context = post('/webhook/internal/context', {
            'conversation_id': second_conversation,
            'max_messages': 20,
        })
        require(status == 200 and isinstance(context, dict), f'Unexpected context response: {context!r}')
        durable = context.get('long_term_memories') or []
        require(any(x.get('memory_key') == 'preference:preferred_code' for x in durable), f'Durable memory missing from second conversation: {context!r}')
        require(marker.casefold() in str(context.get('summary') or '').casefold(), f'Durable memory was not exposed through authoritative summary: {context!r}')

        print('Maya recalls durable memory across conversations...')
        status, maya = post('/webhook/assis/v1/maya/orchestrate', {
            'text': 'Qual é meu código de preferência salvo? Responda apenas com o código.',
            'conversation_id': second_conversation,
            'trace_id': f'{marker}-cross-conversation',
        }, timeout=300)
        require(status == 200 and isinstance(maya, dict), f'Unexpected Maya response: {maya!r}')
        require(maya.get('context_loaded') is True, f'Maya did not load second-conversation context: {maya!r}')
        require(marker.casefold() in str(maya.get('response') or '').casefold(), f'Maya did not recall durable memory across conversations: {maya!r}')

        print('PASS: policy-guarded long-term memory persists per contact and is recalled by Maya across conversations.')
    finally:
        cleanup(org_id)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
