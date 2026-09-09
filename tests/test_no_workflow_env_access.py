from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIRS = [
    ROOT / 'library',
    ROOT / 'starter',
    ROOT / 'professional',
    ROOT / 'enterprise',
]


def test_workflow_json_does_not_access_process_env():
    offenders = []
    for directory in WORKFLOW_DIRS:
        if not directory.exists():
            continue
        for path in directory.rglob('*.json'):
            text = path.read_text(encoding='utf-8')
            if '$env.' in text:
                offenders.append(str(path.relative_to(ROOT)))
    assert not offenders, 'Workflow files still access process environment: ' + ', '.join(offenders)


def test_n8n_env_access_is_blocked_by_default():
    compose = (ROOT / 'core/docker-compose.yml').read_text(encoding='utf-8')
    env_example = (ROOT / '.env.example').read_text(encoding='utf-8')
    assert 'N8N_BLOCK_ENV_ACCESS_IN_NODE: ${N8N_BLOCK_ENV_ACCESS_IN_NODE:-true}' in compose
    assert 'N8N_BLOCK_ENV_ACCESS_IN_NODE=true' in env_example
    assert 'INTERNAL_AGENT_TOKEN: ${INTERNAL_AGENT_TOKEN}' not in compose
