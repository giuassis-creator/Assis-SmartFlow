param(
  [switch]$SkipPublish,
  [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

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
       we."activeVersionId",
       wh."httpMethod",
       wh."path",
       wh."webhookId"
FROM workflow_entity we
LEFT JOIN webhook_entity wh ON wh."workflowId" = we.id
WHERE we."activeVersionId" IS NOT NULL
  AND (
    we.name LIKE 'Internal %'
    OR we.name LIKE 'Library Agent Runtime'
    OR we.name LIKE 'Starter 07 Maya Multi-Agent Orchestrator'
    OR we.name IN ('01 Canonical Ingress','02 Context Load','03 Memory Write','04 Handoff','05 Kanban Upsert','06 RAG Ingest','07 RAG Search','08 DLQ Capture','11 CRM Upsert Contact','12 CRM Update Stage')
  )
ORDER BY we.name, wh.path;
'@
    Write-Host 'Rotas registradas em webhook_entity:'
    & docker exec --env "ASSIS_SQL=$sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -c "$ASSIS_SQL"' | Out-Host
  }

  if ($n8nContainer) {
    Write-Host 'Últimas linhas do log do n8n:'
    & docker logs --tail 120 $n8nContainer 2>&1 | Out-Host
  }
}

Write-Host '=== Assis SmartFlow Core Runtime ==='
Write-Host '1/3 Validando serviços Docker...'
& docker compose @compose ps | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao consultar Docker Compose.' }

Write-Host '2/3 Vinculando credenciais e publicando núcleo seguro...'
& "$PSScriptRoot\configure-core-runtime.ps1" -SkipPublish:$SkipPublish
if ($LASTEXITCODE -ne 0) { throw 'Falha na configuração do Core Runtime.' }

if (-not $SkipSmoke) {
  Write-Host '3/3 Executando homologação integrada do núcleo...'
  & docker compose @compose run --rm qa python scripts/smoke_core_runtime.py
  if ($LASTEXITCODE -ne 0) {
    Show-CoreDiagnostics
    throw 'Homologação do Core Runtime falhou. O diagnóstico acima mostra as rotas registradas e o log do n8n.'
  }
} else {
  Write-Host '3/3 Smoke test ignorado por parâmetro.'
}

Write-Host ''
Write-Host 'PASS: implantação do Core Runtime concluída.'
Write-Host 'Núcleo validado: PostgreSQL + RAG + Policy Gateway + Agent Runtime + Maya/Ollama.'
Write-Host 'Adapters externos continuam desativados até configuração das credenciais/provider adapters.'
