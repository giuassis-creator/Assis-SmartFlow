import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding='utf-8'))


def test_outbound_workflow_is_internal_authenticated_and_idempotent():
    workflow = load('starter/workflows/06-outbound-text.json')
    text = json.dumps(workflow)
    webhook = next(n for n in workflow['nodes'] if n['type'] == 'n8n-nodes-base.webhook')
    assert webhook['parameters']['path'] == 'assis/internal/message/send-text'
    assert '/webhook/assis/internal/auth/verify' in text
    assert 'message.send_text' in text
    assert 'tool_idempotency' in text
    assert 'provider-gateway:8080/v1/evolution/send-text' in text
    assert 'Persist Outbound Message' in text
    assert '$env.' not in text


def test_policy_gateway_routes_reception_send_text_only_through_internal_adapter():
    workflow = load('library/agents/09-tool-policy-gateway.json')
    text = json.dumps(workflow)
    assert "'message.send_text'" in text
    assert 'http://n8n:5678/webhook/assis/internal/message/send-text' in text
    assert "'reception.agent':['knowledge.search','handoff.create','message.send_text']" in text


def test_provider_gateway_keeps_evolution_api_key_out_of_n8n():
    compose = (ROOT / 'core/docker-compose.yml').read_text(encoding='utf-8')
    n8n_block = compose.split('\n  n8n:\n', 1)[1].split('\n  provider-gateway:\n', 1)[0]
    gateway_block = compose.split('\n  provider-gateway:\n', 1)[1].split('\n  ollama:\n', 1)[0]
    assert 'EVOLUTION_API_KEY' not in n8n_block
    assert 'EVOLUTION_INSTANCE' not in n8n_block
    assert 'EVOLUTION_API_KEY: ${EVOLUTION_API_KEY:-}' in gateway_block
    assert 'EVOLUTION_INSTANCE: ${EVOLUTION_INSTANCE:-}' in gateway_block
    assert 'networks: [backend, ai_egress]' in gateway_block


def test_provider_gateway_revalidates_internal_auth_and_supports_explicit_payload_profiles():
    app = (ROOT / 'core/provider-gateway/app.py').read_text(encoding='utf-8')
    assert '/webhook/assis/internal/auth/verify' in app
    assert 'core-internal-agent' in app
    assert 'EVOLUTION_SENDTEXT_PAYLOAD_STYLE' in app
    assert '"textMessage": {"text": text}' in app
    assert '"text": text' in app
    assert '/message/sendText/' in app
    assert '"apikey": EVOLUTION_API_KEY' in app
