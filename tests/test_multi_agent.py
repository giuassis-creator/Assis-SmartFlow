from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def test_registry_has_specialized_agents():
    data=json.loads((ROOT/'core/config/agents.registry.json').read_text()); ids={a['id'] for a in data['agents']}; assert {'reception.agent','calendar.agent','knowledge.agent','crm.agent','finance.agent','document.agent','voice.agent','handoff.agent'}<=ids
def test_internal_agent_endpoints_use_central_auth_without_env_access():
    files=list((ROOT/'library/agents').glob('*-endpoint.json')); assert len(files)>=8
    for p in files:
        raw=p.read_text(); data=json.loads(raw); names={n['name'] for n in data['nodes']}
        assert 'Verify Internal Auth' in names
        assert '/webhook/assis/internal/auth/verify' in raw
        assert '$env.' not in raw
        assert 'x-assis-internal-token' in raw
        assert 'OLLAMA_BASE_URL' in raw
def test_generic_agent_runtime():
    raw=(ROOT/'library/agents/00-agent-runtime.json').read_text(); assert json.loads(raw)['nodes'] and 'tool_allowlist' in raw
def test_tool_policy_gateway():
    raw=(ROOT/'library/agents/09-tool-policy-gateway.json').read_text(); assert 'tool_not_allowed_for_agent' in raw and 'explicit_confirmation_required' in raw
def test_windows_bootstrap():
    assert 'run --rm qa' in (ROOT/'scripts/windows/bootstrap-docker-desktop.ps1').read_text()
def test_rag_search_releases_embedding_model_before_planner():
    data=json.loads((ROOT/'library/workflows/07-rag-search.json').read_text())
    validate=next(node for node in data['nodes'] if node['name']=='Validate Search')
    embed=next(node for node in data['nodes'] if node['name']=='Embed Query Locally')
    assert "keep_alive:0" in validate['parameters']['jsCode']
    assert embed['parameters']['url']=='http://ollama:11434/api/embed'
def test_agent_runtime_bounds_local_generation_without_changing_timeouts():
    data=json.loads((ROOT/'library/agents/00-agent-runtime.json').read_text())
    nodes={node['name']:node for node in data['nodes']}
    for name in ('Prepare Planner Context','Prepare Final Response'):
        code=nodes[name]['parameters']['jsCode']
        assert 'options:{temperature:0,num_predict:256,num_ctx:2048}' in code
    assert nodes['Ollama Agent Planner']['parameters']['options']['timeout']==180000
    assert nodes['Ollama Final Response']['parameters']['options']['timeout']==180000
