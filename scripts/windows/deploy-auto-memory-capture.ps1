$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$workflowPaths = @(
  'library/agents/00-agent-runtime.json',
  'library/workflows/03-memory-write.json',
  'library/workflows/13-auto-memory-capture.json'
)
$workflowNames = @(
  'Library Agent Runtime',
  '03 Memory Write',
  '13 Automatic Durable Memory Capture'
)

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}:`n$($out -join "`n")" }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Invoke-PgScalar([string]$Sql) {
  $postgres = Get-ComposeContainer 'postgres'
  if (-not $postgres) { throw 'Container PostgreSQL não encontrado.' }
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

Write-Host '=== Assis SmartFlow Automatic Durable Memory Capture ==='
Write-Host '1/6 Importando somente Agent Runtime, Memory Write e Auto Capture...'
& "$PSScriptRoot\import-workflows.ps1" -Force -Only $workflowPaths
if ($LASTEXITCODE -ne 0) { throw 'Falha ao importar workflows da captura automática de memória.' }

Write-Host '2/6 Vinculando credencial PostgreSQL nos snapshots atuais...'
& "$PSScriptRoot\bind-postgres-workflow-credentials.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao vincular credencial PostgreSQL.' }

Write-Host '3/6 Publicando somente os workflows desta fase...'
$n8n = Get-ComposeContainer 'n8n'
if (-not $n8n) { throw 'Container n8n não encontrado.' }
foreach ($name in $workflowNames) {
  $escaped = $name.Replace("'","''")
  $sql = @"
SELECT id
FROM workflow_entity
WHERE name='$escaped'
ORDER BY "updatedAt" DESC
LIMIT 1;
"@
  $id = Invoke-PgScalar $sql
  if ([string]::IsNullOrWhiteSpace($id)) { throw "Workflow '$name' não localizado no banco do n8n." }
  $publish = & docker exec -u node $n8n n8n publish:workflow --id=$id 2>&1
  if ($LASTEXITCODE -ne 0 -or (($publish -join "`n") -match '(?i)error|failed|not found')) {
    throw "Falha ao publicar '$name':`n$($publish -join "`n")"
  }
  Write-Host "  PASS: $name publicado."
}

Write-Host '4/6 Recarregando somente o n8n e aquecendo IA local...'
& docker compose @compose up -d --no-deps --force-recreate n8n | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar somente o n8n.' }
$deadline = (Get-Date).AddSeconds(120)
do {
  $n8n = Get-ComposeContainer 'n8n'
  if ($n8n) {
    $ready = & docker exec $n8n sh -lc 'wget -q -O- http://127.0.0.1:5678/healthz >/dev/null 2>&1; echo $?' 2>$null
    if (($ready -join '').Trim() -eq '0') { break }
  }
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ((Get-Date) -ge $deadline) { throw 'n8n não ficou pronto em até 120s.' }
& "$PSScriptRoot\warm-local-ai.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao aquecer IA local.' }

Write-Host '5/6 Validando contratos estáticos de captura e proteção de memória...'
& docker compose @compose --profile tools build qa | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir QA.' }
& docker compose @compose --profile tools run --rm qa pytest -q -p no:cacheprovider tests/test_auto_memory_capture.py tests/test_long_term_memory.py | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha nos contratos estáticos de captura automática de memória.' }

Write-Host '6/6 Homologando captura automática, bloqueio de dado restrito e recall entre conversas...'
$smokeOutput = & docker compose @compose --profile tools run --rm qa python scripts/smoke_auto_memory_capture_runtime.py 2>&1
$smokeExit = $LASTEXITCODE
$smokeOutput | Out-Host
if ($smokeExit -ne 0) {
  Write-Host ''
  Write-Host '=== FALHA ISOLADA DA HOMOLOGAÇÃO ==='
  $stageLines = @($smokeOutput | Where-Object { "$_" -match 'AUTO_MEMORY_STAGE=' })
  if ($stageLines.Count -gt 0) {
    $stageLines | ForEach-Object { Write-Host $_ }
  } else {
    Write-Host 'AUTO_MEMORY_STAGE não apareceu na saída; exibindo as últimas 40 linhas do smoke:'
    @($smokeOutput | Select-Object -Last 40) | Out-Host
  }

  $n8n = Get-ComposeContainer 'n8n'
  if ($n8n) {
    Write-Host '--- últimas 200 linhas do n8n ---'
    & docker logs --tail 200 $n8n 2>&1 | Out-Host
  }
  throw 'Homologação runtime da captura automática de memória falhou. Veja a seção FALHA ISOLADA DA HOMOLOGAÇÃO acima.'
}

Write-Host ''
Write-Host 'PASS: captura automática e segura de fatos duráveis implantada e homologada.'
Write-Host 'Escopo: prefilter determinístico + classificador Ollama local + categorias permitidas + confiança mínima + evidência literal + bloqueio de dados restritos + escrita long-term-only + recall em nova conversa.'
Write-Host 'Nenhum workflow fora de Agent Runtime/Memory Write/Auto Capture foi reimportado ou desativado por esta fase.'
