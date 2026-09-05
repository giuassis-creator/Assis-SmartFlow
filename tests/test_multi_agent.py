from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def test_registry_has_specialized_agents():
    data=json.loads((ROOT/'core/config/agents.registry.json').read_text()); ids={a['id'] for a in data['agents']}; assert {'reception.agent','calendar.agent','knowledge.agent','crm.agent','finance.agent','document.agent','voice.agent','handoff.agent'}<=ids
def test_internal_agent_endpoints_exist_and_use_token():
    files=list((ROOT/'library/agents').glob('*-endpoint.json')); assert len(files)>=8
    for p in files:
        raw=p.read_text(); json.loads(raw); assert 'INTERNAL_AGENT_TOKEN' in raw and 'OLLAMA_BASE_URL' in raw
def test_generic_agent_runtime():
    raw=(ROOT/'library/agents/00-agent-runtime.json').read_text(); assert json.loads(raw)['nodes'] and 'tool_allowlist' in raw
def test_tool_policy_gateway():
    raw=(ROOT/'library/agents/09-tool-policy-gateway.json').read_text(); assert 'tool_not_allowed_for_agent' in raw and 'explicit_confirmation_required' in raw
def test_windows_bootstrap():
    assert 'run --rm qa' in (ROOT/'scripts/windows/bootstrap-docker-desktop.ps1').read_text()
