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

function Invoke-PostgresScalar([string]$Sql) {
  $result = & docker exec --env "ASSIS_SQL=$Sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar PostgreSQL:`n$($result -join "`n")"
  }
  return (($result | Where-Object { $_ }) -join '').Trim()
}

function Invoke-Postgres([string]$Sql) {
  $result = & docker exec --env "ASSIS_SQL=$Sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao executar PostgreSQL:`n$($result -join "`n")"
  }
  return ($result -join "`n")
}

$postgresContainer = Get-ComposeContainer 'postgres'
$n8nContainer = Get-ComposeContainer 'n8n'
if (-not $postgresContainer) { throw 'Container postgres não está em execução.' }
if (-not $n8nContainer) { throw 'Container n8n não está em execução.' }

# Use the n8n CLI as the source of truth for imported workflow IDs. This avoids
# recomputing IDs and guarantees we repair exactly the workflows the n8n
# instance can already see.
$listOutput = & docker exec $n8nContainer n8n list:workflow 2>&1
$listCode = $LASTEXITCODE
if ($listCode -ne 0) {
  throw "Falha ao listar workflows pelo n8n CLI:`n$($listOutput -join "`n")"
}

$workflowRows = @($listOutput | Where-Object { $_ -match '^[0-9a-fA-F-]{36}\|' })
if ($workflowRows.Count -eq 0) {
  throw 'O n8n CLI não retornou workflows. Nenhuma alteração de ownership foi feita.'
}

$workflowIds = @($workflowRows | ForEach-Object { ($_ -split '\|',2)[0].Trim() } | Sort-Object -Unique)
Write-Host "Workflows retornados pelo n8n CLI: $($workflowIds.Count)"

$projectId = Invoke-PostgresScalar 'SELECT p.id FROM project p JOIN project_relation pr ON pr."projectId"=p.id WHERE pr.role=''project:personalOwner'' ORDER BY p."createdAt" LIMIT 1;'
if ([string]::IsNullOrWhiteSpace($projectId)) {
  throw 'Nenhum projeto pessoal do owner foi encontrado. Conclua o setup/login inicial do n8n antes de executar este reparo.'
}
Write-Host "Projeto pessoal do owner: $projectId"

$values = ($workflowIds | ForEach-Object { "('$($_.Replace("'","''"))')" }) -join ','
$escapedProject = $projectId.Replace("'","''")

$existingSql = @"
WITH wanted(id) AS (VALUES $values)
SELECT count(*)
FROM workflow_entity we
JOIN wanted w ON w.id = we.id;
"@
$existingCount = [int](Invoke-PostgresScalar $existingSql)
Write-Host "IDs do CLI encontrados em workflow_entity: $existingCount/$($workflowIds.Count)"
if ($existingCount -ne $workflowIds.Count) {
  $dbInfo = Invoke-PostgresScalar 'SELECT current_database() || ''|'' || current_user || ''|'' || current_schema();'
  throw "O CLI do n8n listou $($workflowIds.Count) workflows, mas este PostgreSQL encontrou apenas $existingCount desses IDs. Conexão consultada: $dbInfo. Nenhuma alteração de ownership foi feita."
}

$repairSql = @"
WITH wanted(id) AS (VALUES $values)
INSERT INTO shared_workflow ("workflowId","projectId",role,"createdAt","updatedAt")
SELECT we.id,'$escapedProject','workflow:owner',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
FROM workflow_entity we
JOIN wanted w ON w.id = we.id
ON CONFLICT ("workflowId","projectId")
DO UPDATE SET role='workflow:owner',"updatedAt"=CURRENT_TIMESTAMP;
"@
Invoke-Postgres $repairSql | Write-Host

$sharedSql = @"
WITH wanted(id) AS (VALUES $values)
SELECT count(*)
FROM shared_workflow sw
JOIN wanted w ON w.id = sw."workflowId"
WHERE sw."projectId" = '$escapedProject'
  AND sw.role = 'workflow:owner';
"@
$sharedCount = [int](Invoke-PostgresScalar $sharedSql)
Write-Host "Ownership workflow:owner confirmado: $sharedCount/$($workflowIds.Count)"
if ($sharedCount -ne $workflowIds.Count) {
  throw 'A associação de ownership não ficou completa. O n8n não será reiniciado.'
}

Write-Host 'Reiniciando somente o serviço n8n para limpar estado em memória...'
& docker compose @compose restart n8n
if ($LASTEXITCODE -ne 0) { throw 'Falha ao reiniciar o serviço n8n.' }

Start-Sleep -Seconds 3
$n8nContainer = Get-ComposeContainer 'n8n'
$listAfter = & docker exec $n8nContainer n8n list:workflow 2>&1
if ($LASTEXITCODE -ne 0 -or (($listAfter -join "`n") -match 'No workflows found')) {
  throw "O CLI não conseguiu listar os workflows após o reparo:`n$($listAfter -join "`n")"
}

Write-Host "PASS: $sharedCount workflows pertencem ao projeto pessoal $projectId."
Write-Host 'Atualize o navegador do n8n. Se necessário, faça logout/login para renovar a sessão e os escopos do projeto.'
