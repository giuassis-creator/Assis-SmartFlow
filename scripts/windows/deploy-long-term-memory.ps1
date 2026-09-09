$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$workflowPaths = @(
  'library/workflows/02-context-load.json',
  'library/workflows/03-memory-write.json'
)
$workflowNames = @('02 Context Load','03 Memory Write')

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

Write-Host '=== Assis SmartFlow Long-Term Memory ==='
Write-Host '1/5 Importando somente Context Load e Memory Write...'
& "$PSScriptRoot\import-workflows.ps1" -Force -Only $workflowPaths
if ($LASTEXITCODE -ne 0) { throw 'Falha ao importar workflows de memória.' }

Write-Host '2/5 Vinculando credencial PostgreSQL nos snapshots atuais...'
& "$PSScriptRoot\bind-postgres-workflow-credentials.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao vincular credencial PostgreSQL.' }

Write-Host '3/5 Publicando somente os workflows de memória...'
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

Write-Host '4/5 Recarregando somente o n8n e validando contratos...'
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
Start-Sleep -Seconds 3

& docker compose @compose --profile tools build qa | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir QA.' }
& docker compose @compose --profile tools run --rm qa pytest -q -p no:cacheprovider tests/test_long_term_memory.py | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha nos contratos estáticos de memória de longo prazo.' }

Write-Host '5/5 Homologando memória durável entre duas conversas do mesmo contato...'
& docker compose @compose --profile tools run --rm qa python scripts/smoke_long_term_memory_runtime.py | Out-Host
if ($LASTEXITCODE -ne 0) {
  $n8n = Get-ComposeContainer 'n8n'
  if ($n8n) {
    Write-Host '--- últimas 160 linhas do n8n ---'
    & docker logs --tail 160 $n8n 2>&1 | Out-Host
  }
  throw 'Homologação runtime de memória de longo prazo falhou.'
}

Write-Host ''
Write-Host 'PASS: memória de longo prazo entre conversas implantada e homologada.'
Write-Host 'Escopo: categorias permitidas + upsert por contato + expiração + recuperação no Context Load + recall pela Maya em nova conversa.'
Write-Host 'Nenhum workflow fora de Context Load/Memory Write foi reimportado ou desativado por esta fase.'
