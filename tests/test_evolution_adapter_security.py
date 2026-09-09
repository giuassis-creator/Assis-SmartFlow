import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding='utf-8'))


def test_evolution_adapter_uses_scoped_hashed_provider_auth_without_env_access():
    workflow = load('starter/workflows/01-evolution-inbound.json')
    webhook = next(n for n in workflow['nodes'] if n['type'] == 'n8n-nodes-base.webhook')
    assert webhook['parameters']['path'] == 'adapter/evolution/in'

    text = json.dumps(workflow)
    code = '\n'.join(
        n.get('parameters', {}).get('jsCode', '')
        for n in workflow['nodes']
        if n['type'] == 'n8n-nodes-base.code'
    )
    assert 'x-assis-secret' in code
    assert 'unauthorized evolution webhook' in code
    assert 'evolution-webhook' in text
    assert '/webhook/assis/internal/auth/verify' in text
    assert '$env.' not in text
    assert 'INTERNAL_AGENT_TOKEN' not in text

    forward = next(n for n in workflow['nodes'] if n['name'] == 'Forward Canonical Ingress')
    assert forward['type'] == 'n8n-nodes-base.httpRequest'
    assert forward['parameters']['url'] == 'http://n8n:5678/webhook/assis/v1/message'
    headers = forward['parameters']['headerParameters']['parameters']
    assert any(h.get('name') == 'x-assis-provider-token' for h in headers)
    assert any(
        h.get('name') == 'x-assis-auth-scope' and h.get('value') == 'evolution-webhook'
        for h in headers
    )


def test_canonical_ingress_accepts_only_known_scoped_provider_auth():
    workflow = load('library/workflows/01-canonical-ingress.json')
    text = json.dumps(workflow)
    code = '\n'.join(
        n.get('parameters', {}).get('jsCode', '')
        for n in workflow['nodes']
        if n['type'] == 'n8n-nodes-base.code'
    )
    assert 'x-assis-provider-token' in text
    assert "['evolution-webhook','chatwoot-webhook'].includes(scope)" in code
    assert 'secret_name=scope' in code
    assert '/webhook/assis/internal/auth/verify' in text


def test_internal_auth_verifier_allows_only_explicit_secret_scopes():
    workflow = load('library/agents/11-internal-auth-verify.json')
    text = json.dumps(workflow)
    assert 'core-internal-agent' in text
    assert 'evolution-webhook' in text
    assert 'chatwoot-webhook' in text
    assert 'auth secret scope denied' in text
    assert 'name=$2' in text


def test_evolution_secret_stays_out_of_n8n_process_environment():
    compose = (ROOT / 'core/docker-compose.yml').read_text(encoding='utf-8')
    env_example = (ROOT / '.env.example').read_text(encoding='utf-8')
    assert 'EVOLUTION_WEBHOOK_SECRET: ${EVOLUTION_WEBHOOK_SECRET:-}' not in compose
    assert 'EVOLUTION_WEBHOOK_SECRET=CHANGE_ME_LONG_RANDOM_EVOLUTION_SECRET' in env_example
