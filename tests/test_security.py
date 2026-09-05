from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def test_no_localhost_provider_urls():
    assert not [str(p) for p in ROOT.rglob('*.json') if 'http://localhost' in p.read_text().lower()]
def test_identity_rule_present():
    assert 'nunca diga que é ia' in (ROOT/'core/config/secretary-system-prompt.md').read_text().lower()
def test_postgres_queries_parameterized():
    for base in ['library','starter','professional','enterprise']:
        for p in (ROOT/base).rglob('*.json'):
            for node in json.loads(p.read_text()).get('nodes',[]):
                if node.get('type')=='n8n-nodes-base.postgres' and node.get('parameters',{}).get('operation')=='executeQuery':
                    params=node['parameters']; query=params.get('query',''); assert '{{$json' not in query
                    if '$1' in query: assert params.get('options',{}).get('queryReplacement')
