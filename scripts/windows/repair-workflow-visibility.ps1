$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$imports = @(
  'library/agents',
  'library/workflows',
  'starter/workflows',
  'professional/workflows',
  'enterprise/workflows'
)

function Get-DeterministicGuid([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
  } finally {
    $sha.Dispose()
  }
  $bytes = New-Object byte[] 16
  [Array]::Copy($hash, 0, $bytes, 0, 16)
  return ([Guid]::new($bytes)).ToString()
}

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

$projectId = Invoke-PostgresScalar 'SELECT p.id FROM project p JOIN project_relation pr ON pr."projectId"=p.id WHERE pr.role=''project:personalOwner'' ORDER BY p."createdAt" LIMIT 1;'
if ([string]::IsNullOrWhiteSpace($projectId)) {
  throw 'Nenhum projeto pessoal do owner foi encontrado. Conclua o setup/login inicial do n8n antes de executar este reparo.'
}
Write-Host "Projeto pessoal do owner: $projectId"

$workflowIds = New-Object System.Collections.Generic.List[string]
foreach ($dir in $imports) {
  $hostDir = Join-Path $root $dir
  if (-not (Test-Path $hostDir)) { continue }
  Get-ChildItem -Path $hostDir -Filter '*.json' -File | Where-Object {
    $_.Name -notin @('manifest.json','catalog.json')
  } | ForEach-Object {
    $relativePath = ($dir + '/' + $_.Name).Replace('\\','/').ToLowerInvariant()
    $workflow = Get-Content -Raw -Path $_.FullName | ConvertFrom-Json -Depth 100
    $id = if ($workflow.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$workflow.id)) {
      [string]$workflow.id
    } else {
      Get-DeterministicGuid "assis-workflow:$relativePath"
    }
    $workflowIds.Add($id)
  }
}

$workflowIds = @($workflowIds | Sort-Object -Unique)
if ($workflowIds.Count -eq 0) { throw 'Nenhum workflow Assis SmartFlow foi encontrado no repositório.' }
Write-Host "Workflows Assis SmartFlow esperados: $($workflowIds.Count)"

$values = ($workflowIds | ForEach-Object { "('$($_.Replace("'","''"))')" }) -join ','
$escapedProject = $projectId.Replace("'","''")

$existingSql = "WITH wanted(id) AS (VALUES $values) SELECT count(*) FROM workflow_entity we JOIN wanted w ON w.id=we.id;"
$existingCount = [int](Invoke-PostgresScalar $existingSql)
Write-Host "Workflows encontrados em workflow_entity: $existingCount"
if ($existingCount -ne $workflowIds.Count) {
  throw "Esperados $($workflowIds.Count) workflows, mas apenas $existingCount existem no banco. Não alterei ownership."
}

$repairSql = @"
WITH wanted(id) AS (VALUES $values)
INSERT INTO shared_workflow ("workflowId","projectId",role,"createdAt","updatedAt")
SELECT we.id,'$escapedProject','workflow:owner',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
FROM workflow_entity we
JOIN wanted w ON w.id=we.id
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
$listOutput = & docker exec $n8nContainer n8n list:workflow 2>&1
if ($LASTEXITCODE -ne 0 -or (($listOutput -join "`n") -match 'No workflows found')) {
  throw "O CLI não conseguiu listar os workflows após o reparo:`n$($listOutput -join "`n")"
}

Write-Host "PASS: $sharedCount workflows Assis SmartFlow pertencem ao projeto pessoal $projectId."
Write-Host 'Atualize o navegador do n8n. Se o painel já estava aberto, faça logout/login para renovar a sessão e os escopos do projeto.'
