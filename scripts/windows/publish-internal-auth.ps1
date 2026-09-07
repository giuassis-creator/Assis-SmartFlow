$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar o serviço ${Service}:`n$($out -join "`n")" }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

$postgresContainer = Get-ComposeContainer 'postgres'
$n8nContainer = Get-ComposeContainer 'n8n'
if (-not $postgresContainer) { throw 'Container postgres não está em execução.' }
if (-not $n8nContainer) { throw 'Container n8n não está em execução.' }

$sql = @'
SELECT id
FROM workflow_entity
WHERE name = 'Internal Auth Verify'
ORDER BY "updatedAt" DESC
LIMIT 1;
'@
$workflowId = & docker exec --env "ASSIS_SQL=$sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
if ($LASTEXITCODE -ne 0) { throw "Falha ao localizar Internal Auth Verify:`n$($workflowId -join "`n")" }
$workflowId = (($workflowId | Where-Object { $_ }) -join '').Trim()
if ([string]::IsNullOrWhiteSpace($workflowId)) { throw 'Workflow Internal Auth Verify não encontrado após importação.' }

$unresolvedSql = @"
SELECT count(*)
FROM workflow_entity
WHERE id = '$($workflowId.Replace("'","''"))'
  AND nodes::text LIKE '%ASSIS_POSTGRES%';
"@
$unresolved = & docker exec --env "ASSIS_SQL=$unresolvedSql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Falha ao validar credencial do Internal Auth Verify.' }
if ([int](($unresolved | Where-Object { $_ }) -join '').Trim() -ne 0) { throw 'Internal Auth Verify ainda possui referência ASSIS_POSTGRES.' }

Write-Host "Publicando: Internal Auth Verify ($workflowId)"
$publishOutput = & docker exec -u node $n8nContainer n8n publish:workflow --id=$workflowId 2>&1
if ($LASTEXITCODE -ne 0 -or (($publishOutput -join "`n") -match '(?i)error|failed|not found')) {
  throw "Falha ao publicar Internal Auth Verify:`n$($publishOutput -join "`n")"
}

Write-Host 'Reiniciando somente o n8n para registrar o webhook de autenticação...'
& docker compose @compose restart n8n
if ($LASTEXITCODE -ne 0) { throw 'Falha ao reiniciar o n8n após publicar autenticação interna.' }

$activeSql = @"
SELECT count(*)
FROM workflow_entity
WHERE id = '$($workflowId.Replace("'","''"))'
  AND "activeVersionId" IS NOT NULL;
"@
$active = & docker exec --env "ASSIS_SQL=$activeSql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
if ($LASTEXITCODE -ne 0 -or [int](($active | Where-Object { $_ }) -join '').Trim() -ne 1) { throw 'Internal Auth Verify não possui activeVersionId.' }

Write-Host 'PASS: Internal Auth Verify publicado com credencial PostgreSQL vinculada.'
