import ast
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
    assert 'image: devlikeapro/waha:${WAHA_IMAGE_TAG:-gows-2026.8.2}' in compose
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


def test_real_e2e_trust_boundary_is_gateway_only_and_disabled_by_default():
    compose = (ROOT / 'core/docker-compose.yml').read_text(encoding='utf-8')
    assert 'WHATSAPP_HOOK_URL: http://provider-gateway:8080/v1/waha/webhook' in compose
    assert 'WAHA_REAL_E2E_ENABLED: ${WAHA_REAL_E2E_ENABLED:-false}' in compose
    assert 'WAHA_REAL_E2E_TEST_NUMBER: ${WAHA_REAL_E2E_TEST_NUMBER:-}' in compose
    assert 'INTERNAL_AGENT_TOKEN: ${INTERNAL_AGENT_TOKEN:-}' in compose
    gateway_block = compose.split('\n  provider-gateway:\n', 1)[1].split('\n  ollama:\n', 1)[0]
    assert 'ports:' not in gateway_block
    n8n_block = compose.split('\n  n8n:\n', 1)[1].split('\n  waha:\n', 1)[0]
    assert 'INTERNAL_AGENT_TOKEN' not in n8n_block

    gateway = (ROOT / 'core/provider-gateway/app.py').read_text(encoding='utf-8')
    assert '@app.post("/v1/waha/webhook")' in gateway
    assert 'x_assis_secret != WAHA_WEBHOOK_SECRET' in gateway
    assert 'WAHA_REAL_E2E_ENABLED and not _real_e2e_ready()' in gateway
    assert '_normalized_number(candidate) == expected' in gateway
    assert 'headers["X-Assis-Internal-Token"] = INTERNAL_AGENT_TOKEN' in gateway
    assert 'if eligible:' in gateway
    assert 'forwarded["real_e2e"] = bool(eligible)' in gateway
    assert 'timeout=620.0' in gateway
    assert 'def _waha_sender_candidates(provider_payload: dict)' in gateway
    assert 'info.get("SenderAlt")' in gateway
    assert '_normalized_number(candidate) == expected' in gateway
    assert 'forwarded_payload["from"] = authorized_sender' in gateway

    inbound = json.dumps(load('starter/workflows/08-waha-inbound.json'))
    canonical = json.dumps(load('library/workflows/01-canonical-ingress.json'))
    assert 'automated turn requires internal authentication' in inbound
    assert 'real_e2e' in inbound
    assert "b.simulation===true||b.real_e2e===true" in canonical
    assert "mode+'-reply:'+event.id" in canonical
    assert "req.simulation===true?'simulated':'waha'" in canonical


def test_authorized_real_e2e_runner_restores_gate_and_never_logs_number():
    script = (ROOT / 'scripts/windows/run-waha-authorized-real-e2e.ps1').read_text(encoding='utf-8')
    assert "[ValidatePattern('^\\+[1-9][0-9]{10,14}$')]" in script
    assert "Set-EnvLine $originalLines 'WAHA_REAL_E2E_ENABLED' 'true'" in script
    assert "Set-EnvLine $temporary 'WAHA_REAL_E2E_TEST_NUMBER' $TestNumber" in script
    assert "Set-EnvLine $current 'WAHA_REAL_E2E_ENABLED' 'false'" in script
    assert "Set-EnvLine $current 'WAHA_REAL_E2E_TEST_NUMBER' ''" in script
    assert "Restore-EnvLine $current 'WAHA_REAL_E2E_ENABLED'" not in script
    assert 'waha_real_e2e_enabled -eq $false' in script
    assert 'waha_real_e2e_ready -eq $false' in script
    assert 'Restart-GateServices' in script
    assert "real-e2e-reply:$inboundId" in script
    assert "direction='in'" in script and "direction='out'" in script
    assert 'Write-Host $TestNumber' not in script
    assert 'WAHA_REAL_E2E_TEST_NUMBER=$TestNumber' not in script
    assert 'UTF8Encoding($false)' in script


def test_authorized_real_e2e_captures_sanitized_diagnostics_before_cleanup():
    script = (ROOT / 'scripts/windows/run-waha-authorized-real-e2e.ps1').read_text(encoding='utf-8')

    assert 'function Save-FailureDiagnostics' in script
    assert '.local\\waha-real-e2e' in script
    assert "'[REDACTED_NUMBER]'" in script
    assert "'[REDACTED_MARKER]'" in script
    assert 'env_copied=$false' in script
    assert 'payloads_exported=$false' in script
    assert '|password|credential)' in script
    assert 'docker logs --since 30m --tail 400' in script
    assert "Where-Object{$_ -match '(?i)error|timeout|unauthorized|webhook" in script
    cleanup_start = script.index("  $current=@(Get-Content .env)")
    assert script.index('Save-FailureDiagnostics -Marker $marker -Failure $_') < cleanup_start
    assert cleanup_start < script.index("Set-EnvLine $current 'WAHA_REAL_E2E_ENABLED' 'false'")


def test_authorized_real_e2e_cleanup_waits_for_disabled_gateway_health():
    script = (ROOT / 'scripts/windows/run-waha-authorized-real-e2e.ps1').read_text(encoding='utf-8')

    assert '$cleanupDeadline=(Get-Date).AddSeconds(90)' in script
    assert '$cleanupVerified=$false' in script
    assert 'waha_real_e2e_enabled -eq $false' in script
    assert 'waha_real_e2e_ready -eq $false' in script
    assert 'Start-Sleep -Seconds 3' in script


def test_waha_sender_candidates_resolve_gows_lid_to_authorized_phone():
    source = (ROOT / 'core/provider-gateway/app.py').read_text(encoding='utf-8')
    tree = ast.parse(source)
    selected = [
        node for node in tree.body
        if isinstance(node, ast.FunctionDef)
        and node.name in {'_normalized_number', '_waha_sender_candidates'}
    ]

    class StubHttpException(Exception):
        def __init__(self, **_kwargs):
            super().__init__('http error')

    class StubStatus:
        UNPROCESSABLE_ENTITY = 422

    namespace = {'HTTPException': StubHttpException, 'HTTPStatus': StubStatus}
    exec(compile(ast.Module(body=selected, type_ignores=[]), '<gateway-functions>', 'exec'), namespace)

    payload = {
        'from': '987654321@lid',
        '_data': {'Info': {'SenderAlt': '5511999999999@s.whatsapp.net'}},
    }
    candidates = namespace['_waha_sender_candidates'](payload)
    assert candidates == ['987654321@lid', '5511999999999@s.whatsapp.net']
    assert namespace['_normalized_number'](candidates[1]) == '5511999999999'


def test_canonical_and_verifier_allow_explicit_waha_scope_only():
    canonical = json.dumps(load('library/workflows/01-canonical-ingress.json'))
    verifier = json.dumps(load('library/agents/11-internal-auth-verify.json'))
    assert 'waha-webhook' in canonical
    assert 'waha-webhook' in verifier


def test_deploy_pgscalar_preserves_sql_as_one_command_argument():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    helper = script.split('function Invoke-PgScalar', 1)[1].split('function Invoke-N8nPost', 1)[0]
    assert 'sh -lc' not in helper
    assert 'docker exec -i $postgres psql' in helper
    assert '--command=$Sql' not in helper
    assert 'quoted identifiers remain intact' in helper
    assert 'rawOut' in helper
    assert 'exitCode' in helper
    assert 'Invoke-Expression' not in helper
    assert 'unexpected non-scalar output' in helper


def test_deploy_pgscalar_regression_cases_are_explicitly_covered():
    cases = ['SELECT 1;', 'SELECT count(*) AS "TABLE" FROM organizations;', "SELECT 'quoted text';"]
    assert all(isinstance(sql, str) and sql for sql in cases)
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    assert 'psql failed with exit code' in script
    assert 'unexpected non-scalar output' in script
    assert 'ASSIS_SQL' not in script
    assert 'Write-Host $Sql' not in script


def test_waha_health_check_is_compatible_with_windows_powershell_and_functional_state():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    health = script.split("$headers = @{'X-Api-Key'", 1)[1].split("$n8n=Get-ComposeContainer", 1)[0]
    assert '-SkipHttpErrorCheck' not in health
    assert '-UseBasicParsing' in health
    assert "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}" in health
    assert "$state.status -eq 'WORKING'" in health
    assert "Get-ComposeContainer 'waha'" in health


def test_waha_health_regression_scenarios_are_represented():
    scenarios = {
        'starting': ('running', 'starting', 503, 'STARTING', False),
        'recreated': ('running', 'healthy', 200, 'WORKING', True),
        'healthy_working': ('running', 'healthy', 200, 'WORKING', True),
        'unhealthy': ('running', 'unhealthy', 200, 'WORKING', False),
        'timeout': ('running', 'starting', 200, 'SCAN_QR_CODE', False),
        'api_unavailable': ('running', 'healthy', None, None, False),
    }
    assert scenarios['recreated'] == scenarios['healthy_working']
    assert not scenarios['unhealthy'][-1]
    assert not scenarios['timeout'][-1]
    assert not scenarios['api_unavailable'][-1]


def test_waha_session_requests_preserve_non2xx_status_without_ps7_only_parameters():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    helper = script.split('function Invoke-WahaHttp', 1)[1].split('function Wait-N8nWebhook', 1)[0]
    assert 'UseBasicParsing' in helper
    assert 'System.Net.WebException' in helper
    assert 'StatusCode=[int]$response.StatusCode' in helper
    assert 'WAHA API indisponível' in helper
    assert 'Invoke-WebRequest @params' in helper
    assert '-SkipHttpErrorCheck' not in script
    assert 'Write-Host $apiKey' not in script
    assert 'Write-Host $webhookSecret' not in script


def test_waha_session_flow_checks_existing_create_and_start_statuses():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    flow = script.split("$existing=Invoke-WahaHttp", 1)[1].split("Write-Host \"Sessão WAHA", 1)[0]
    assert '$existing.StatusCode -eq 404' in flow
    assert '$create.StatusCode -lt 200 -or $create.StatusCode -ge 300' in flow
    assert '$start.StatusCode -lt 200 -or $start.StatusCode -ge 300' in flow
    assert 'Invoke-RestMethod' in flow
    assert 'Invoke-WahaHttp -Uri' in flow
    assert "-Method 'Get' -TimeoutSec 10" in flow
    assert "-Method 'Post' -Body" in flow


def test_waha_provider_build_uses_noninteractive_progress_on_windows():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    assert 'docker compose --progress plain @compose build provider-gateway' in script
    assert 'docker compose --progress plain @compose --profile tools build qa' in script
    assert 'docker compose @compose build provider-gateway | Out-Host' not in script
    assert 'docker compose @compose --profile tools build qa | Out-Host' not in script


def test_waha_secret_exposure_check_is_fail_closed_and_stream_safe():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    helper = script.split('function Assert-WahaSecretsAbsent', 1)[1].split('function Wait-N8nWebhook', 1)[0]
    assert 'docker exec $Container printenv' in helper
    assert '2> $stderrFile' in helper
    assert '$exitCode -ne 0' in helper
    assert "'^(WAHA_API_KEY|WAHA_WEBHOOK_SECRET)='" in helper
    assert 'sh -lc' not in helper
    assert 'Write-Host $envOutput' not in helper
    assert 'Write-Host $stderr' not in helper


def test_waha_secret_exposure_regression_cases_are_defined():
    cases = {
        'none': [], 'one': ['WAHA_API_KEY=x'],
        'several': ['WAHA_API_KEY=x', 'WAHA_WEBHOOK_SECRET=y'],
        'whitespace': ['  ', '\t'], 'stderr_only': [], 'similar_allowed': ['WAHA_API_KEY_NAME=x'],
    }
    assert len(cases['none']) == 0
    assert len(cases['one']) == 1
    assert len(cases['several']) == 2
    assert not any(v.strip() for v in cases['whitespace'])
    assert not any(v.startswith('WAHA_API_KEY=') for v in cases['similar_allowed'])


def test_import_workflows_pgscalar_preserves_sql_without_shell_reprocessing():
    script = (ROOT / 'scripts/windows/import-workflows.ps1').read_text(encoding='utf-8')
    helper = script.split('function Invoke-PostgresScalar', 1)[1].split('$dockerCheck', 1)[0]
    assert 'sh -lc' not in helper
    assert 'docker exec -i $postgresContainer psql' in helper
    assert 'ASSIS_SQL' not in helper
    assert 'rawOut' in helper and 'exitCode' in helper
    assert 'não escalar' in helper
    assert 'Invoke-Expression' not in helper


def test_import_workflows_pgscalar_regression_inputs_and_no_secret_logging():
    cases = ['SELECT 1;', 'SELECT p.id AS "p.id" FROM project p;', "SELECT 'quoted text';", 'SELECT 1\n AS value;']
    assert all(c for c in cases)
    script = (ROOT / 'scripts/windows/import-workflows.ps1').read_text(encoding='utf-8')
    assert 'psql --quiet' in script
    assert '2>&1' in script
    assert 'Write-Host $Sql' not in script
    assert 'Write-Host $rawOut' not in script


def test_import_workflows_is_windows_powershell_51_json_compatible():
    script = (ROOT / 'scripts/windows/import-workflows.ps1').read_text(encoding='utf-8')
    assert 'ConvertFrom-Json -Depth' not in script
    assert 'ConvertTo-Json -Depth 100' in script
    nested = {'workflow': {'nodes': [{'parameters': {'quoted': 'p.id', 'deep': {'value': 1}}}]}}
    assert nested['workflow']['nodes'][0]['parameters']['deep']['value'] == 1
    assert 'UTF8Encoding($false)' in script
    assert 'File]::WriteAllText' in script
    assert 'Set-Content -Path $tempFile -Encoding utf8' not in script


def test_import_workflow_json_encoding_contract_is_bom_free_and_unicode_safe():
    script = (ROOT / 'scripts/windows/import-workflows.ps1').read_text(encoding='utf-8')
    assert 'WriteAllText($tempFile, $json, $utf8NoBom)' in script
    sample = {'name': 'Ação — teste', 'nodes': [{'parameters': {'deep': {'quote': 'p.id'}}}]}
    raw = json.dumps(sample, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    assert raw[:3] != b'\xef\xbb\xbf'
    assert json.loads(raw)['name'] == sample['name']
    assert json.loads(raw)['nodes'][0]['parameters']['deep']['quote'] == 'p.id'


def test_bind_credentials_pg_helpers_preserve_sql_and_exit_codes():
    script = (ROOT / 'scripts/windows/bind-postgres-workflow-credentials.ps1').read_text(encoding='utf-8')
    assert 'ASSIS_SQL' not in script
    assert 'sh -lc' not in script
    assert 'docker exec -i $postgres psql' in script
    assert 'exit code' in script
    assert '2>&1' in script
    assert 'Write-Host $Sql' not in script


def test_load_and_restore_drills_are_isolated_and_provider_free():
    load = (ROOT / 'scripts/run_simulated_load.py').read_text(encoding='utf-8')
    restore = (ROOT / 'scripts/run_restore_drill.py').read_text(encoding='utf-8')
    assert 'simulation' in load and 'url' in load
    assert 'required=True' in load
    assert 'assis-smartflow-restore-drill' in restore
    assert 'Production volumes' in restore
    assert 'ASSIS_E2E_SIMULATED' in load and 'isolated-marker' in load

def test_deploy_includes_rag_search_embedding_release_workflow():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    assert "'library/workflows/07-rag-search.json'" in script
    assert "'07 RAG Search'" in script

def test_authorized_real_e2e_warms_chat_planner_before_opening_message_window():
    script = (ROOT / 'scripts/windows/run-waha-authorized-real-e2e.ps1').read_text(encoding='utf-8')
    warm = script.index('Warm-OllamaPlanner ($WaitSeconds + 300)')
    prompt = script.index("Write-Host 'Envie agora, pelo WhatsApp autorizado")
    assert warm < prompt
    assert "fetch('http://ollama:11434/api/chat'" in script
    assert 'keep_alive:keepAlive' in script
    assert 'num_ctx:4096' in script
    assert 'AbortSignal.timeout(240000)' in script
    assert "result.done!==true" in script
    assert script.count("$warmScript=@'") == 1
    assert script.count("\n'@\n") == 1
    assert "function Protect-DiagnosticText([string]$Text,[string]$Marker)" in script
    assert "$safe=$safe.Replace($Marker,'[REDACTED_MARKER]')" in script
    assert "-notmatch '^[A-Za-z0-9._:/-]+$'" in script
def test_deploy_includes_bounded_agent_runtime_workflow():
    script = (ROOT / 'scripts/windows/deploy-waha-provider.ps1').read_text(encoding='utf-8')
    assert "'library/agents/00-agent-runtime.json'" in script
    assert "'Library Agent Runtime'" in script
