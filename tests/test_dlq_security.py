import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_dlq_requires_internal_auth_before_database():
    path = ROOT / 'library/workflows/08-dlq.json'
    workflow = json.loads(path.read_text())
    names = [node['name'] for node in workflow['nodes']]
    assert 'Authorize DLQ' in names
    assert 'Verify DLQ Auth' in names
    assert 'Enforce DLQ Auth' in names

    auth_code = ' '.join(
        node.get('parameters', {}).get('jsCode', '')
        for node in workflow['nodes']
        if node.get('type') == 'n8n-nodes-base.code'
    )
    assert 'x-assis-internal-token' in auth_code
    assert '/webhook/assis/internal/auth/verify' in json.dumps(workflow)

    postgres_index = next(
        i for i, node in enumerate(workflow['nodes'])
        if node.get('type') == 'n8n-nodes-base.postgres'
    )
    enforce_index = names.index('Enforce DLQ Auth')
    assert enforce_index < postgres_index


def test_dlq_schema_is_owned_by_core_migration():
    core_migration = (ROOT / 'core/db/migrations/006_core_dlq.sql').read_text(encoding='utf-8')
    enterprise_migration = (ROOT / 'core/db/migrations/002_enterprise.sql').read_text(encoding='utf-8')
    apply_script = (ROOT / 'scripts/windows/apply-core-dlq-schema.ps1').read_text(encoding='utf-8')

    assert 'CREATE TABLE IF NOT EXISTS dead_letter_events' in core_migration
    assert 'idx_dlq_retry' in core_migration
    assert 'idx_dlq_event_key' in core_migration
    assert 'dead_letter_events' not in enterprise_migration
    assert '006_core_dlq.sql' in apply_script
    assert 'to_regclass' in apply_script
