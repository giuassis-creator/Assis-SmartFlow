import json
import os
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

BASE = os.getenv('N8N_INTERNAL_URL', 'http://n8n:5678').rstrip('/')
TOKEN = os.getenv('INTERNAL_AGENT_TOKEN', '')


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

        print('Maya multi-agent orchestrator + local Ollama...')
        status, maya = post('/webhook/assis/v1/maya/orchestrate', {
            'text': 'Olá, gostaria de saber como vocês podem me ajudar.',
            'organization_id': org,
            'trace_id': marker,
        }, auth, timeout=240)
        require(status == 200, 'Maya orchestrator did not return 200')
        require(isinstance(maya, dict), f'Unexpected Maya response: {maya!r}')
        require(maya.get('orchestrated') is True, f'Maya was not orchestrated: {maya!r}')
        require(bool(maya.get('response')), f'Maya returned an empty response: {maya!r}')
        require(maya.get('provider') == 'ollama', f'Maya did not use local Ollama: {maya!r}')
    else:
        print('WARN: INTERNAL_AGENT_TOKEN unavailable; agent-runtime smoke skipped.')

    print('PASS: core runtime, RAG, policy gateway and Maya multi-agent chain are operational.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
