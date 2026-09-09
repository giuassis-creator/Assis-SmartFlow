import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding='utf-8'))


def test_provider_registry_is_tenant_scoped_and_secret_free():
    sql = (ROOT / 'core/db/migrations/007_whatsapp_provider_registry.sql').read_text(encoding='utf-8')
    assert 'organization_whatsapp_providers' in sql
    assert "provider IN ('waha','wppconnect','evolution','meta')" in sql
    assert 'PRIMARY KEY (organization_id, provider, session_name)' in sql
    assert 'Secrets must never be stored here' in sql


def test_waha_is_internal_persistent_and_default_provider():
    compose = (ROOT / 'core/docker-compose.yml').read_text(encoding='utf-8')
    assert 'image: devlikeapro/waha:${WAHA_VERSION:-2026.8.2}' in compose
    assert 'WHATSAPP_DEFAULT_ENGINE: ${WAHA_ENGINE:-GOWS}' in compose
    assert 'waha_sessions:/app/.sessions' in compose
    assert 'waha_media:/app/.media' in compose
    assert 'WHATSAPP_PROVIDER_DEFAULT: ${WHATSAPP_PROVIDER_DEFAULT:-waha}' in compose
    waha_block = compose.split('\n  waha:\n', 1)[1].split('\n  provider-gateway:\n', 1)[0]
    assert 'ports:' not in waha_block


def test_provider_gateway_supports_waha_and_legacy_evolution_without_n8n_secrets():
    app = (ROOT / 'core/provider-gateway/app.py').read_text(encoding='utf-8')
    assert '/v1/whatsapp/send-text' in app
    assert 'WAHA_BASE_URL' in app
    assert '/api/sendText' in app
    assert 'X-Api-Key' in app
    assert 'provider == "waha"' in app
    assert 'provider == "evolution"' in app
    compose = (ROOT / 'core/docker-compose.yml').read_text(encoding='utf-8')
    n8n_block = compose.split('\n  n8n:\n', 1)[1].split('\n  waha:\n', 1)[0]
    assert 'WAHA_API_KEY' not in n8n_block
    assert 'WAHA_WEBHOOK_SECRET' not in n8n_block


def test_outbound_resolves_provider_by_organization_before_dispatch():
    workflow = load('starter/workflows/06-outbound-text.json')
    text = json.dumps(workflow)
    assert 'organization_whatsapp_providers' in text
    assert 'Load WhatsApp Provider Route' in text
    assert '/v1/whatsapp/send-text' in text
    assert 'provider:$json.provider' in text
    assert 'session:$json.session' in text


def test_waha_inbound_is_scoped_authenticated_and_resolves_session_tenant():
    workflow = load('starter/workflows/08-waha-inbound.json')
    text = json.dumps(workflow)
    assert 'adapter/waha/in' in text
    assert 'waha-webhook' in text
    assert 'organization_whatsapp_providers' in text
    assert "p.provider='waha'" in text
    assert 'x-assis-auth-scope' in text
    assert '$env.' not in text


def test_canonical_and_verifier_allow_explicit_waha_scope_only():
    canonical = json.dumps(load('library/workflows/01-canonical-ingress.json'))
    verifier = json.dumps(load('library/agents/11-internal-auth-verify.json'))
    assert 'waha-webhook' in canonical
    assert 'waha-webhook' in verifier
