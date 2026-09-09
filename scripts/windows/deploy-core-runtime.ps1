param(
  [switch]$SkipPublish,
  [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$coreImportPaths = @(
  'library/agents/00-agent-runtime.json',
  'library/agents/01-reception-agent-endpoint.json',
  'library/agents/02-calendar-agent-endpoint.json',
  'library/agents/03-knowledge-agent-endpoint.json',
  'library/agents/04-crm-agent-endpoint.json',
  'library/agents/05-finance-agent-endpoint.json',
  'library/agents/06-document-agent-endpoint.json',
  'library/agents/07-voice-agent-endpoint.json',
  'library/agents/08-handoff-agent-endpoint.json',
  'library/agents/09-tool-policy-gateway.json',
  'library/agents/10-tool-noop.json',
  'library/agents/11-internal-auth-verify.json',
  'library/workflows/01-canonical-ingress.json',
  'library/workflows/02-context-load.json',
  'library/workflows/03-memory-write.json',
  'library/workflows/04-handoff.json',
  'library/workflows/05-kanban-upsert.json',
  'library/workflows/06-rag-ingest.json',
  'library/workflows/07-rag-search.json',
  'library/workflows/08-dlq.json',
  'library/workflows/11-crm-upsert-contact.json',
  'library/workflows/12-crm-update-stage.json',
  'library/workflows/13-auto-memory-capture.json',
  'starter/workflows/07-multi-agent-orchestrator.json'
)

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar o serviço ${Service}:`n$($out -join "`n")"
  }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Show-CoreDiagnostics {
  Write-Host ''
  Write-Host '=== Diagnóstico automático do Core Runtime ==='
  $postgresContainer = Get-ComposeContainer 'postgres'
  $n8nContainer = Get-ComposeContainer 'n8n'

  if ($postgresContainer) {
    $sql = @'
SELECT we.name,
       we.id,
       we."versionId",
       we."activeVersionId",
       COALESCE(jsonb_agg(to_jsonb(wh)) FILTER (WHERE wh."workflowId" IS NOT NULL), '[]'::jsonb) AS webhooks
FROM workflow_entity we
LEFT JOIN webhook_entity wh ON wh."workflowId" = we.id
WHERE we."activeVersionId" IS NOT NULL
  AND (
    we.name LIKE 'Internal %'
    OR we.name = 'Library Agent Runtime'
    OR we.name = 'Starter 07 Maya Multi-Agent Orchestrator'
    OR we.name IN ('01 Canonical Ingress','02 Context Load','03 Memory Write','04 Handoff','05 Kanban Upsert','06 RAG Ingest','07 RAG Search','08 DLQ Capture','11 CRM Upsert Contact','12 CRM Update Stage','13 Automatic Durable Memory Capture')
  )
GROUP BY we.name, we.id, we."versionId", we."activeVersionId"
ORDER BY we.name;
'@
    Write-Host 'Estado publicado e registros brutos de webhook_entity:'
    & docker exec --env "ASSIS_SQL=$sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -c "$ASSIS_SQL"' | Out-Host
  }

  if ($n8nContainer) {
    Write-Host 'Últimas linhas do log do n8n:'
    & docker logs --tail 180 $n8nContainer 2>&1 | Out-Host
  }
}

Write-Host '=== Assis SmartFlow Core Runtime ==='
Write-Host '1/5 Validando serviços Docker...'
& docker compose @compose ps | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao consultar Docker Compose.' }

Write-Host '2/5 Aplicando hardening de rede e proxy...'
& "$PSScriptRoot\apply-network-hardening.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao aplicar hardening de rede/proxy.' }

Write-Host '3/5 Sincronizando somente workflows do Core com o n8n...'
& "$PSScriptRoot\import-workflows.ps1" -Force -Only $coreImportPaths
if ($LASTEXITCODE -ne 0) { throw 'Falha ao sincronizar workflows do Core com o n8n.' }

Write-Host '4/5 Configurando autenticação interna, vinculando credenciais e publicando núcleo seguro...'
& "$PSScriptRoot\configure-internal-auth.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha na configuração da autenticação interna.' }
& "$PSScriptRoot\bind-postgres-workflow-credentials.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao vincular credenciais PostgreSQL nos workflows/snapshots.' }
& "$PSScriptRoot\configure-core-runtime.ps1" -SkipPublish:$SkipPublish
if ($LASTEXITCODE -ne 0) { throw 'Falha na configuração do Core Runtime.' }
if (-not $SkipPublish) {
  & "$PSScriptRoot\publish-internal-auth.ps1"
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao publicar o verificador de autenticação interna.' }
}

if (-not $SkipSmoke) {
  Write-Host '5/5 Executando homologação integrada do núcleo...'
  Write-Host 'Atualizando imagem QA para refletir dependências e testes atuais...'
  & docker compose @compose build qa | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir a imagem QA.' }

  Write-Host 'Validando contratos estáticos de Handoff/Kanban/CRM, DLQ e memória automática...'
  & docker compose @compose run --rm qa pytest -q -p no:cacheprovider tests/test_business_ops_security.py tests/test_dlq_security.py tests/test_auto_memory_capture.py | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'Falha nos contratos estáticos de Handoff/Kanban/CRM/DLQ/memória automática.' }

  & "$PSScriptRoot\warm-local-ai.ps1"
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao aquecer a IA local antes da homologação.' }
  Write-Host 'Aguardando o n8n concluir o carregamento das rotas de produção (até 120s)...'
  & docker compose @compose run --rm qa python scripts/smoke_core_runtime.py
  if ($LASTEXITCODE -ne 0) {
    Show-CoreDiagnostics
    throw 'Homologação do Core Runtime falhou. O diagnóstico acima mostra o estado publicado, webhooks e log do n8n.'
  }

  Write-Host 'Homologando Handoff, Kanban e CRM pelo Policy Gateway...'
  & docker compose @compose run --rm qa python scripts/smoke_business_ops_runtime.py
  if ($LASTEXITCODE -ne 0) {
    Show-CoreDiagnostics
    throw 'Homologação runtime de Handoff/Kanban/CRM falhou.'
  }
} else {
  Write-Host '5/5 Smoke test ignorado por parâmetro.'
}

Write-Host ''
Write-Host 'PASS: implantação do Core Runtime concluída.'
Write-Host 'Núcleo validado: PostgreSQL + autenticação interna por hash + endpoints internos protegidos + DLQ autenticada + RAG automático + memória curta/longa + captura automática guardada + Handoff + Kanban + CRM + Policy Gateway + Agent Runtime + Maya/Ollama.'
Write-Host 'Workflows fora do Core não foram reimportados nem desativados por este deploy.'
