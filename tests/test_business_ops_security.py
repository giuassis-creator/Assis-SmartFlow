import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

WORKFLOWS = [
    ROOT / 'library/workflows/04-handoff.json',
    ROOT / 'library/workflows/05-kanban-upsert.json',
    ROOT / 'library/workflows/11-crm-upsert-contact.json',
    ROOT / 'library/workflows/12-crm-update-stage.json',
]


def load(path):
    return json.loads(path.read_text())


def test_business_ops_require_internal_auth_before_database():
    for path in WORKFLOWS:
        workflow = load(path)
        names = [n['name'] for n in workflow['nodes']]
        assert any('Authorize' in name for name in names), path
        assert any('Verify' in name and 'Auth' in name for name in names), path
        assert any('Enforce' in name and 'Auth' in name for name in names), path
        auth_code = ' '.join(
            n.get('parameters', {}).get('jsCode', '')
            for n in workflow['nodes']
            if n.get('type') == 'n8n-nodes-base.code'
        )
        assert 'x-assis-internal-token' in auth_code, path
        assert '/webhook/assis/internal/auth/verify' in json.dumps(workflow), path
        postgres_nodes = [n for n in workflow['nodes'] if n.get('type') == 'n8n-nodes-base.postgres']
        assert postgres_nodes, path
        for node in postgres_nodes:
            assert node.get('credentials', {}).get('postgres', {}).get('id') == 'ASSIS_POSTGRES', path


def test_policy_gateway_propagates_auth_to_business_ops():
    gateway = load(ROOT / 'library/agents/09-tool-policy-gateway.json')
    text = json.dumps(gateway)
    for tool, route in {
        'handoff.create': '/webhook/internal/handoff',
        'kanban.upsert_card': '/webhook/internal/kanban/upsert',
        'crm.upsert_contact': '/webhook/internal/crm/upsert-contact',
        'crm.update_stage': '/webhook/internal/crm/update-stage',
    }.items():
        assert tool in text
        assert route in text
    assert 'x-assis-internal-token' in text
