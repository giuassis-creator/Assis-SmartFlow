import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads((ROOT / path).read_text())


def test_auto_capture_is_authenticated_and_policy_guarded():
    workflow = load('library/workflows/13-auto-memory-capture.json')
    names = [node['name'] for node in workflow['nodes']]
    text = json.dumps(workflow, ensure_ascii=False)
    code = ' '.join(
        node.get('parameters', {}).get('jsCode', '')
        for node in workflow['nodes']
        if node.get('type') == 'n8n-nodes-base.code'
    )

    assert 'Authorize Auto Capture' in names
    assert 'Verify Auto Capture Auth' in names
    assert 'Enforce Auto Capture Auth' in names
    assert names.index('Enforce Auto Capture Auth') < names.index('Classify Durable Fact')
    assert '/webhook/assis/internal/auth/verify' in text
    assert "['preference','profile','relationship','business_context']" in code
    assert 'confidence>=0.9' in code
    assert "source:'automatic_explicit_fact'" in code
    assert 'write_short_term:false' in code
    assert 'senha' in code and 'api[ -]?key' in code and 'diagn' in code
    assert 'toLocaleLowerCase' in code


def test_memory_write_can_skip_short_term_without_erasing_summary():
    workflow = load('library/workflows/03-memory-write.json')
    text = json.dumps(workflow)
    code = ' '.join(
        node.get('parameters', {}).get('jsCode', '')
        for node in workflow['nodes']
        if node.get('type') == 'n8n-nodes-base.code'
    )
    assert 'write_short_term' in code
    assert 'WHERE $9::boolean' in text
    assert "$json.write_short_term ? 'true' : 'false'" in text


def test_agent_runtime_runs_auto_capture_as_best_effort():
    workflow = load('library/agents/00-agent-runtime.json')
    nodes = {node['name']: node for node in workflow['nodes']}
    text = json.dumps(workflow)
    assert 'Automatic Durable Memory Capture' in nodes
    assert '/webhook/internal/memory/auto-capture' in text
    assert nodes['Automatic Durable Memory Capture'].get('onError') == 'continueRegularOutput'
    assert 'long_term_memory_captured' in text
