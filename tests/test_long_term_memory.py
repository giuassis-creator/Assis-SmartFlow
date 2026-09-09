import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads((ROOT / path).read_text())


def test_memory_write_supports_policy_guarded_long_term_upsert():
    workflow = load('library/workflows/03-memory-write.json')
    text = json.dumps(workflow)
    code = ' '.join(
        node.get('parameters', {}).get('jsCode', '')
        for node in workflow['nodes']
        if node.get('type') == 'n8n-nodes-base.code'
    )
    assert "['preference','profile','relationship','business_context']" in code
    assert 'memory_key and memory_value required for long-term memory' in code
    assert 'long_term_memory' in text
    assert 'ON CONFLICT(organization_id,contact_id,memory_key)' in text
    assert 'conv.contact_id IS NOT NULL' in text


def test_context_load_includes_unexpired_contact_long_term_memory():
    workflow = load('library/workflows/02-context-load.json')
    text = json.dumps(workflow)
    assert 'long_term_memory' in text
    assert 'long_term_memories' in text
    assert 'ltm.organization_id=c.organization_id' in text
    assert 'ltm.contact_id=c.contact_id' in text
    assert 'ltm.expires_at IS NULL OR ltm.expires_at>now()' in text
    assert 'Memória durável do contato' in text
