#!/usr/bin/env python3
import json
import os
import sys
import time
import uuid
from urllib.error import HTTPError, URLError
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


def post(path, payload, token=None, timeout=90, expect_success=True):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['x-assis-internal-token'] = token
    req = Request(BASE + path, data=json.dumps(payload).encode('utf-8'), headers=headers, method='POST')
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode('utf-8')
            data = json.loads(raw) if raw else {}
            if not expect_success:
                raise RuntimeError(f'{path} unexpectedly accepted invalid authentication')
            return resp.status, data
    except HTTPError as exc:
        raw = exc.read().decode('utf-8', errors='replace')
        if expect_success:
            raise RuntimeError(f'{path} HTTP {exc.code}: {raw}') from exc
        return exc.code, raw
    except URLError as exc:
        raise RuntimeError(f'{path} unreachable: {exc}') from exc


def pg_connect():
    require(PG_DB and PG_USER and PG_PASSWORD, 'PostgreSQL QA credentials are unavailable')
    return psycopg.connect(host=PG_HOST, dbname=PG_DB, user=PG_USER, password=PG_PASSWORD)


def gateway(agent_id, tool, arguments, organization_id, conversation_id=None):
    payload = {
        'agent_id': agent_id,
        'organization_id': organization_id,
        'conversation_id': conversation_id,
        'trace_id': f'business-ops-{uuid.uuid4()}',
        'tool_call': {'name': tool, 'arguments': arguments},
    }
    return post('/webhook/assis/internal/tool/execute', payload, TOKEN)


def create_fixture():
    marker = uuid.uuid4().hex
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                'INSERT INTO organizations(slug,name,config) VALUES(%s,%s,%s::jsonb) RETURNING id::text',
                (f'business-ops-{marker}', 'Assis SmartFlow Business Ops Smoke', json.dumps({'smoke_test': True})),
            )
            organization_id = cur.fetchone()[0]
            cur.execute(
                'INSERT INTO contacts(organization_id,external_id,name,metadata) VALUES(%s::uuid,%s,%s,%s::jsonb) RETURNING id::text',
                (organization_id, f'seed-{marker}', 'Seed Contact', json.dumps({'smoke_test': True})),
            )
            seed_contact_id = cur.fetchone()[0]
            cur.execute(
                'INSERT INTO conversations(organization_id,contact_id,channel,external_id,context,last_message_at) VALUES(%s::uuid,%s::uuid,%s,%s,%s::jsonb,now()) RETURNING id::text',
                (organization_id, seed_contact_id, 'smoke', f'conversation-{marker}', json.dumps({'smoke_test': True})),
            )
            conversation_id = cur.fetchone()[0]
        conn.commit()
    return marker, organization_id, conversation_id


def cleanup(organization_id):
    if not organization_id:
        return
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute('DELETE FROM organizations WHERE id=%s::uuid', (organization_id,))
        conn.commit()


def main():
    require(TOKEN and not TOKEN.startswith('CHANGE_ME'), 'INTERNAL_AGENT_TOKEN unavailable')
    marker, organization_id, conversation_id = create_fixture()
    bad_token = f'invalid-{marker}'
    try:
        print('Business endpoints reject invalid direct calls...')
        post('/webhook/internal/handoff', {'conversation_id': conversation_id, 'reason': 'blocked', 'summary': 'blocked'}, bad_token, expect_success=False)
        post('/webhook/internal/kanban/upsert', {'organization_id': organization_id, 'title': 'blocked'}, bad_token, expect_success=False)
        post('/webhook/internal/crm/upsert-contact', {'organization_id': organization_id, 'external_id': f'blocked-{marker}'}, bad_token, expect_success=False)
        post('/webhook/internal/crm/update-stage', {'organization_id': organization_id, 'contact_id': '00000000-0000-4000-8000-000000000000', 'stage': 'blocked'}, bad_token, expect_success=False)

        print('CRM upsert through Policy Gateway...')
        external_id = f'customer-{marker}'
        status, contact = gateway('crm.agent', 'crm.upsert_contact', {
            'external_id': external_id,
            'name': 'Business Ops Smoke',
            'phone': '+5500000000000',
            'metadata': {'smoke_test': True},
        }, organization_id, conversation_id)
        require(status == 200 and isinstance(contact, dict), f'Unexpected CRM upsert response: {contact!r}')
        contact_id = str(contact.get('id') or '')
        require(contact_id, f'CRM upsert did not return contact id: {contact!r}')

        print('CRM stage update through Policy Gateway...')
        status, staged = gateway('crm.agent', 'crm.update_stage', {
            'contact_id': contact_id,
            'stage': 'qualificado',
        }, organization_id, conversation_id)
        require(status == 200 and isinstance(staged, dict), f'Unexpected CRM stage response: {staged!r}')
        metadata = staged.get('metadata') or {}
        require(metadata.get('stage') == 'qualificado', f'CRM stage was not persisted: {staged!r}')

        print('Kanban upsert through Policy Gateway...')
        status, card = gateway('crm.agent', 'kanban.upsert_card', {
            'title': '[Assis SmartFlow QA] business ops card',
            'lane': 'qualificando',
            'priority': 'normal',
            'metadata': {'smoke_test': True},
        }, organization_id, conversation_id)
        require(status == 200 and isinstance(card, dict) and card.get('id'), f'Kanban card was not created: {card!r}')

        print('Handoff through Policy Gateway...')
        status, handoff = gateway('handoff.agent', 'handoff.create', {
            'reason': 'runtime_homologation',
            'summary': 'Temporary handoff generated by automated smoke test.',
            'priority': 'normal',
            'recent_messages': [{'direction': 'inbound', 'body': 'smoke'}],
            'destination': 'human',
        }, organization_id, conversation_id)
        require(status == 200 and isinstance(handoff, dict) and handoff.get('id'), f'Handoff was not persisted: {handoff!r}')

        with pg_connect() as conn:
            with conn.cursor() as cur:
                cur.execute('SELECT status FROM conversations WHERE id=%s::uuid', (conversation_id,))
                require(cur.fetchone()[0] == 'waiting_human', 'Handoff did not set conversation status to waiting_human')
                cur.execute('SELECT count(*) FROM kanban_cards WHERE organization_id=%s::uuid AND metadata->>\'smoke_test\'=\'true\'', (organization_id,))
                require(cur.fetchone()[0] >= 1, 'Kanban smoke card not found in PostgreSQL')
                cur.execute('SELECT count(*) FROM handoffs WHERE organization_id=%s::uuid AND reason=\'runtime_homologation\'', (organization_id,))
                require(cur.fetchone()[0] == 1, 'Handoff smoke row not found in PostgreSQL')

        print('PASS: Handoff, Kanban and CRM reject invalid direct access and operate through the authenticated Policy Gateway.')
    finally:
        cleanup(organization_id)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
