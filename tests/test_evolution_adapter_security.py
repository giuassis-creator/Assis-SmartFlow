import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding='utf-8'))


def test_evolution_adapter_requires_provider_secret_and_forwards_with_internal_token():
    workflow = load('starter/workflows/01-evolution-inbound.json')
    webhook = next(n for n in workflow['nodes'] if n['type'] == 'n8n-nodes-base.webhook')
    assert webhook['parameters']['path'] == 'adapter/evolution/in'

    code = '\n'.join(
        n.get('parameters', {}).get('jsCode', '')
        for n in workflow['nodes']
        if n['type'] == 'n8n-nodes-base.code'
    )
    assert 'EVOLUTION_WEBHOOK_SECRET' in code
    assert 'x-assis-secret' in code
    assert 'unauthorized evolution webhook' in code
    assert 'length<32' in code

    forward = next(n for n in workflow['nodes'] if n['name'] == 'Forward Canonical Ingress')
    assert forward['type'] == 'n8n-nodes-base.httpRequest'
    assert forward['parameters']['url'] == 'http://n8n:5678/webhook/assis/v1/message'
    headers = forward['parameters']['headerParameters']['parameters']
    assert any(
        h.get('name') == 'x-assis-internal-token'
        and 'INTERNAL_AGENT_TOKEN' in h.get('value', '')
        for h in headers
    )


def test_evolution_secret_is_wired_into_runtime_configuration():
    compose = (ROOT / 'core/docker-compose.yml').read_text(encoding='utf-8')
    env_example = (ROOT / '.env.example').read_text(encoding='utf-8')
    assert 'EVOLUTION_WEBHOOK_SECRET: ${EVOLUTION_WEBHOOK_SECRET:-}' in compose
    assert 'EVOLUTION_WEBHOOK_SECRET=CHANGE_ME_LONG_RANDOM_EVOLUTION_SECRET' in env_example
