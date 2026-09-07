import json
import os
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

import psycopg

BASE = os.getenv('N8N_INTERNAL_URL', 'http://n8n:5678').rstrip('/')
TOKEN = os.getenv('INTERNAL_AGENT_TOKEN', '')
PG_HOST = os.getenv('POSTGRES_HOST', 'postgres')
PG_DB = os.getenv('POSTGRES_DB', '')
PG_USER = os.getenv('POSTGRES_USER', '')
PG_PASSWORD = os.getenv('POSTGRES_PASSWORD', '')


def post(path, payload, headers=None, timeout=180):
    body = json.dumps(payload).encode('utf-8')
    h = {'Content-Type': 'application/json'}
    if headers:
        h.update(headers)
    req = Request(BASE + path, data=body, headers=h, method='POST')
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode('utf-8')
            return resp.status, json.loads(raw) if raw else None
    except HTTPError as exc:
        raw = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f'{path} HTTP {exc.code}: {raw}') from exc
    except URLError as exc:
        raise RuntimeError(f'{path} unreachable: {exc}') from exc


def wait_for_production_webhook(path, payload, timeout=120):
    deadline = time.time() + timeout
    last_error = None
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        try:
            status, data = post(path, payload, timeout=15)
            if status == 200:
                print(f'Production webhook ready after {attempt} attempt(s).')
                return status, data
        except Exception as exc:
            last_error = exc
        time.sleep(3)
    raise RuntimeError(
        f'n8n production webhook did not become ready within {timeout}s: {last_error}'
    )


def require(cond, message):
    if not cond:
        raise RuntimeError(message)


def pg_connect():
    require(PG_DB and PG_USER and PG_PASSWORD, 'PostgreSQL QA credentials are unavailable')
    return psycopg.connect(host=PG_HOST, dbname=PG_DB, user=PG_USER, password=PG_PASSWORD)


def create_smoke_conversation(marker):
    slug = f'smoke-memory-{marker.lower()}'
    external_id = f'conversation-{marker.lower()}'
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                'INSERT INTO organizations(slug,name,config) VALUES(%s,%s,%s::jsonb) RETURNING id',
                (slug, 'Assis SmartFlow Memory Smoke', json.dumps({'smoke_test': True})),
            )
            organization_id = str(cur.fetchone()[0])
            cur.execute(
                'INSERT INTO contacts(organization_id,external_id,name,metadata) VALUES(%s::uuid,%s,%s,%s::jsonb) RETURNING id',
                (organization_id, f'contact-{marker.lower()}', 'Smoke Contact', json.dumps({'smoke_test': True})),
            )
            contact_id = str(cur.fetchone()[0])
            cur.execute(
                'INSERT INTO conversations(organization_id,contact_id,channel,external_id,context,last_message_at) VALUES(%s::uuid,%s::uuid,%s,%s,%s::jsonb,now()) RETURNING id',
                (organization_id, contact_id, 'smoke', external_id, json.dumps({'smoke_test': True})),
            )
            conversation_id = str(cur.fetchone()[0])
        conn.commit()
    return organization_id, conversation_id


def delete_smoke_organization(organization_id):
    if not organization_id:
        return
    with pg_connect() as conn:
        with conn.cursor() as cur:
            cur.execute('DELETE FROM organizations WHERE id=%s::uuid', (organization_id,))
        conn.commit()


def main():
    print('Waiting for n8n production webhook registration...')
    status, noop = wait_for_production_webhook(
        '/webhook/assis/internal/tool/noop',
        {'blocked': True, 'reason': 'smoke-readiness', 'tool': None},
    )
    require(status == 200, 'Tool noop did not return 200')
    require(isinstance(noop, dict) and noop.get('executed') is False, f'Unexpected noop response: {noop!r}')

    print('RAG ingest...')
    org = 'assis-smoke'
    marker = f'ASSIS_SMOKE_{int(time.time())}'
    status, ingest = post('/webhook/internal/rag/ingest', {
        'organization_id': org,
        'document_id': marker,
        'title': 'Assis SmartFlow Smoke Knowledge',
        'content': f'{marker} A secretária padrão se chama Maya e o núcleo utiliza RAG local.',
        'checksum': marker,
        'metadata': {'smoke_test': True},
    })
    require(status == 200, 'RAG ingest did not return 200')

    print('RAG search...')
    status, search = post('/webhook/internal/rag/search', {
        'organization_id': org,
        'query': marker,
        'top_k': 3,
    })
    require(status == 200, 'RAG search did not return 200')
    require(isinstance(search, dict), f'Unexpected RAG response: {search!r}')
    require(search.get('paid_api_used') is False, 'RAG unexpectedly reported paid API usage')
    require(search.get('count', 0) >= 1, f'RAG smoke marker not found: {search!r}')

    if TOKEN:
        auth = {'x-assis-internal-token': TOKEN}
        print('Policy gateway no-tool path...')
        status, policy = post('/webhook/assis/internal/tool/execute', {
            'agent_id': 'reception.agent',
            'tool_call': None,
            'trace_id': marker,
        }, auth)
        require(status == 200, 'Policy gateway did not return 200')
        require(isinstance(policy, dict) and policy.get('executed') is False, f'Unexpected policy response: {policy!r}')

        print('Maya multi-agent orchestrator + automatic RAG + local Ollama...')
        status, maya = post('/webhook/assis/v1/maya/orchestrate', {
            'text': f'O que você sabe sobre {marker}?',
            'organization_id': org,
            'trace_id': marker,
        }, auth, timeout=300)
        require(status == 200, 'Maya orchestrator did not return 200')
        require(isinstance(maya, dict), f'Unexpected Maya response: {maya!r}')
        require(maya.get('orchestrated') is True, f'Maya was not orchestrated: {maya!r}')
        require(bool(maya.get('response')), f'Maya returned an empty response: {maya!r}')
        require(maya.get('provider') == 'ollama', f'Maya did not use local Ollama: {maya!r}')
        require(maya.get('rag_count', 0) >= 1, f'Maya did not retrieve RAG context automatically: {maya!r}')
        require(maya.get('context_loaded') is False, f'Unexpected conversation context in smoke call: {maya!r}')
        require(maya.get('memory_written') is False, f'Unexpected memory write without conversation_id: {maya!r}')

        print('Conversation memory: two-turn context load + memory write...')
        smoke_org_id = None
        try:
            memory_marker = f'MEMORY_{int(time.time())}'
            smoke_org_id, conversation_id = create_smoke_conversation(memory_marker)

            first_text = f'Guarde nesta conversa que meu código de preferência é {memory_marker}.'
            status, first = post('/webhook/assis/v1/maya/orchestrate', {
                'text': first_text,
                'conversation_id': conversation_id,
                'trace_id': f'{memory_marker}-turn-1',
            }, auth, timeout=300)
            require(status == 200, 'Maya memory turn 1 did not return 200')
            require(isinstance(first, dict), f'Unexpected memory turn 1 response: {first!r}')
            require(first.get('context_loaded') is True, f'Conversation context was not loaded on turn 1: {first!r}')
            require(first.get('memory_written') is True, f'Conversation memory was not written on turn 1: {first!r}')

            status, remembered = post('/webhook/internal/context', {
                'conversation_id': conversation_id,
                'max_messages': 20,
            })
            require(status == 200, 'Context verification after turn 1 did not return 200')
            require(isinstance(remembered, dict), f'Unexpected context verification response: {remembered!r}')
            require(memory_marker in str(remembered.get('summary') or ''), f'Memory marker was not persisted after turn 1: {remembered!r}')

            status, second = post('/webhook/assis/v1/maya/orchestrate', {
                'text': 'Qual é meu código de preferência desta conversa? Responda apenas com o código.',
                'conversation_id': conversation_id,
                'trace_id': f'{memory_marker}-turn-2',
            }, auth, timeout=300)
            require(status == 200, 'Maya memory turn 2 did not return 200')
            require(isinstance(second, dict), f'Unexpected memory turn 2 response: {second!r}')
            require(second.get('context_loaded') is True, f'Conversation context was not loaded on turn 2: {second!r}')
            require(second.get('memory_written') is True, f'Conversation memory was not updated on turn 2: {second!r}')
            require(memory_marker.lower() in str(second.get('response') or '').lower(), f'Maya did not recall the previous-turn memory marker: {second!r}')
        finally:
            delete_smoke_organization(smoke_org_id)
    else:
        print('WARN: INTERNAL_AGENT_TOKEN unavailable; agent-runtime smoke skipped.')

    print('PASS: core runtime, automatic RAG, two-turn memory, policy gateway and Maya multi-agent chain are operational.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
