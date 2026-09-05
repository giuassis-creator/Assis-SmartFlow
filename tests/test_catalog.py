import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def test_mcp_write_tools_require_idempotency():
    exceptions={'handoff.create'}
    for p in (ROOT/'mcp/catalog').glob('*.json'):
        d=json.loads(p.read_text())
        if d.get('side_effect') and d['name'] not in exceptions: assert 'idempotency_key' in d['input']['required'],d['name']
def test_mcp_versions_semver():
    for p in (ROOT/'mcp/catalog').glob('*.json'):
        parts=json.loads(p.read_text())['version'].split('.'); assert len(parts)==3 and all(x.isdigit() for x in parts)
