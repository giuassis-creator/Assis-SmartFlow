param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$markerDir = Join-Path $root '.local'
$marker = Join-Path $markerDir 'workflow-import-v6.done'
$tempDir = Join-Path $markerDir 'workflow-import'
if ((Test-Path $marker) -and -not $Force) {
  Write-Host 'Workflows já importados e validados neste clone. Use -Force apenas para revalidar/reimportar.'
  exit 0
}
New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$imports = @(
  @{ Host = 'library/agents' },
  @{ Host = 'library/workflows' },
  @{ Host = 'starter/workflows' },
  @{ Host = 'professional/workflows' },
  @{ Host = 'enterprise/workflows' }
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

function Test-DockerEngine {
  $output = & docker version --format '{{json .Server}}' 2>&1
  $code = $LASTEXITCODE
  return @{ Ok = ($code -eq 0 -and $output); Output = ($output -join "`n") }
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

$dockerCheck = Test-DockerEngine
if (-not $dockerCheck.Ok) {
  Write-Host $dockerCheck.Output
  throw "Docker Desktop Linux Engine não está respondendo. Abra/reinicie o Docker Desktop e confirme com 'docker version' e 'docker ps'. Se DOCKER_API_VERSION estiver definido manualmente, remova com: Remove-Item Env:DOCKER_API_VERSION -ErrorAction SilentlyContinue. Não use docker compose down -v."
}

$n8nContainer = Get-ComposeContainer 'n8n'
$postgresContainer = Get-ComposeContainer 'postgres'
if (-not $n8nContainer) { throw 'Container n8n não está em execução.' }
if (-not $postgresContainer) { throw 'Container postgres não está em execução.' }

$projectId = Invoke-PostgresScalar 'SELECT p.id FROM project p JOIN project_relation pr ON pr."projectId"=p.id WHERE pr.role=''project:personalOwner'' ORDER BY p."createdAt" LIMIT 1;'
if (-not $projectId) {
  $projectId = Invoke-PostgresScalar 'SELECT id FROM project ORDER BY "createdAt" LIMIT 1;'
}
$useProjectId = -not [string]::IsNullOrWhiteSpace($projectId)
if ($useProjectId) {
  Write-Host "Projeto n8n de destino: $projectId"
} else {
  Write-Warning 'Nenhum projeto n8n existe ainda. Importando sem --projectId. Após concluir o setup/login do owner, reexecute este script com -Force para associar os workflows ao projeto pessoal.'
}

$filesToImport = @()
foreach ($entry in $imports) {
  $hostDir = Join-Path $root $entry.Host
  if (-not (Test-Path $hostDir)) { continue }
  $filesToImport += Get-ChildItem -Path $hostDir -Filter '*.json' -File | Where-Object {
    $_.Name -notin @('manifest.json','catalog.json')
  } | ForEach-Object {
    [PSCustomObject]@{ Entry = $entry; File = $_ }
  }
}
$filesToImport = $filesToImport | Sort-Object { $_.Entry.Host }, { $_.File.Name }
if (-not $filesToImport -or $filesToImport.Count -eq 0) {
  throw 'Nenhum workflow JSON foi encontrado para importação.'
}

Write-Host "Workflows encontrados para importação: $($filesToImport.Count)"
& docker exec $n8nContainer sh -lc 'mkdir -p /tmp/assis-import'
if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar diretório temporário no n8n.' }

foreach ($item in $filesToImport) {
  $entry = $item.Entry
  $file = $item.File
  $relativePath = ($entry.Host + '/' + $file.Name).Replace('\\','/').ToLowerInvariant()
  $workflow = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json -Depth 100

  if (-not $workflow.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$workflow.id)) {
    $workflow | Add-Member -NotePropertyName id -NotePropertyValue (Get-DeterministicGuid "assis-workflow:$relativePath") -Force
  }
  if (-not $workflow.PSObject.Properties['versionId'] -or [string]::IsNullOrWhiteSpace([string]$workflow.versionId)) {
    $workflow | Add-Member -NotePropertyName versionId -NotePropertyValue (Get-DeterministicGuid "assis-version:$relativePath") -Force
  }

  $safeName = ($relativePath -replace '[^a-z0-9._-]','_')
  $tempFile = Join-Path $tempDir $safeName
  $workflow | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $tempFile -Encoding utf8
  $containerFile = "/tmp/assis-import/$safeName"

  Write-Host "  -> $relativePath [$($workflow.id)]"
  & docker cp $tempFile "${n8nContainer}:$containerFile"
  if ($LASTEXITCODE -ne 0) { throw "Falha ao copiar workflow: $relativePath" }

  if ($useProjectId) {
    & docker exec $n8nContainer n8n import:workflow "--input=$containerFile" "--projectId=$projectId"
  } else {
    & docker exec $n8nContainer n8n import:workflow "--input=$containerFile"
  }
  if ($LASTEXITCODE -ne 0) { throw "Falha ao importar workflow: $relativePath" }
}

$dbCountText = Invoke-PostgresScalar 'SELECT count(*) FROM workflow_entity;'
[int]$dbCount = 0
if (-not [int]::TryParse($dbCountText, [ref]$dbCount) -or $dbCount -lt 1) {
  throw "Importação não persistiu workflows em workflow_entity (count=$dbCountText). Marcador de sucesso NÃO foi criado."
}

if ($useProjectId) {
  $sharedSql = 'SELECT count(*) FROM shared_workflow WHERE "projectId"=''' + $projectId.Replace("'", "''") + ''';'
  $sharedCountText = Invoke-PostgresScalar $sharedSql
  [int]$sharedCount = 0
  if (-not [int]::TryParse($sharedCountText, [ref]$sharedCount) -or $sharedCount -lt 1) {
    throw "Workflows existem no banco, mas não foram associados ao projeto $projectId (shared_workflow count=$sharedCountText). Marcador NÃO foi criado."
  }
}

$listOutput = & docker exec $n8nContainer n8n list:workflow 2>&1
$listCode = $LASTEXITCODE
$listText = ($listOutput -join "`n")
if ($listCode -ne 0 -or $listText -match 'No workflows found') {
  throw "n8n ainda não consegue listar workflows após a importação:`n$listText"
}

Set-Content -Path $marker -Value (Get-Date).ToString('o') -Encoding ascii
if ($useProjectId) {
  Write-Host "PASS: $dbCount workflow(s) persistidos e associados ao projeto $projectId."
} else {
  Write-Host "PASS: $dbCount workflow(s) persistidos e visíveis no CLI. Nenhum projeto n8n existe ainda; finalize o setup do owner e depois reexecute com -Force."
}
Write-Host 'Workflows importados e validados. Eles permanecem desativados por segurança até as credenciais/provedores serem configurados.'
