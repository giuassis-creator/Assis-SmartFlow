param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$markerDir = Join-Path $root '.local'
$marker = Join-Path $markerDir 'workflow-import-v2.done'
$tempDir = Join-Path $markerDir 'workflow-import'
if ((Test-Path $marker) -and -not $Force) {
  Write-Host 'Workflows já importados neste clone. Use -Force apenas se você souber que deseja reimportá-los.'
  exit 0
}
New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$imports = @(
  @{ Host = 'library/agents';          Container = '/opt/assis/library/agents' },
  @{ Host = 'library/workflows';       Container = '/opt/assis/library/workflows' },
  @{ Host = 'starter/workflows';       Container = '/opt/assis/starter/workflows' },
  @{ Host = 'professional/workflows';  Container = '/opt/assis/professional/workflows' },
  @{ Host = 'enterprise/workflows';    Container = '/opt/assis/enterprise/workflows' }
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

$dockerCheck = Test-DockerEngine
if (-not $dockerCheck.Ok) {
  Write-Warning 'Docker Desktop não respondeu à negociação normal da API.'
  Write-Host $dockerCheck.Output
  if (-not $env:DOCKER_API_VERSION) {
    Write-Host 'Tentando compatibilidade temporária com Docker Engine API v1.51...'
    $env:DOCKER_API_VERSION = '1.51'
    $dockerCheck = Test-DockerEngine
  }
}
if (-not $dockerCheck.Ok) {
  throw "Docker Desktop Linux Engine não está respondendo corretamente. Reinicie o Docker Desktop e confirme com 'docker version' e 'docker ps'. Não use docker compose down -v."
}

$n8nOutput = & docker compose @compose ps -q n8n 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao consultar o serviço n8n no Docker Desktop:`n$($n8nOutput -join "`n")"
}
$n8nContainer = (($n8nOutput | Where-Object { $_ }) -join '').Trim()
if (-not $n8nContainer) {
  throw "Container n8n não está em execução. Execute: docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml up -d n8n"
}

foreach ($entry in $imports) {
  $hostDir = Join-Path $root $entry.Host
  if (-not (Test-Path $hostDir)) {
    Write-Host "Diretório não encontrado, ignorando: $($entry.Host)"
    continue
  }

  Write-Host "Importando $($entry.Host) ..."
  $files = Get-ChildItem -Path $hostDir -Filter '*.json' -File | Where-Object {
    $_.Name -notin @('manifest.json','catalog.json')
  } | Sort-Object Name

  foreach ($file in $files) {
    $relativePath = ($entry.Host + '/' + $file.Name).Replace('\\','/').ToLowerInvariant()
    $workflow = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json -Depth 100

    if (-not $workflow.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$workflow.id)) {
      $workflow | Add-Member -NotePropertyName id -NotePropertyValue (Get-DeterministicGuid "assis-workflow:$relativePath") -Force
    }
    if (-not $workflow.PSObject.Properties['versionId'] -or [string]::IsNullOrWhiteSpace([string]$workflow.versionId)) {
      $workflow | Add-Member -NotePropertyName versionId -NotePropertyValue (Get-DeterministicGuid "assis-version:$relativePath") -Force
    }

    $safeName = (($relativePath -replace '[^a-z0-9._-]','_'))
    $tempFile = Join-Path $tempDir $safeName
    $workflow | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $tempFile -Encoding utf8

    $containerFile = "/tmp/assis-import/$safeName"
    Write-Host "  -> $relativePath [$($workflow.id)]"
    & docker exec $n8nContainer sh -lc 'mkdir -p /tmp/assis-import'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar diretório temporário no n8n.' }
    & docker cp $tempFile "${n8nContainer}:$containerFile"
    if ($LASTEXITCODE -ne 0) { throw "Falha ao copiar workflow: $relativePath" }
    & docker exec $n8nContainer n8n import:workflow "--input=$containerFile"
    if ($LASTEXITCODE -ne 0) {
      throw "Falha ao importar workflow: $relativePath"
    }
  }
}

Set-Content -Path $marker -Value (Get-Date).ToString('o') -Encoding ascii
Write-Host 'Workflows importados com IDs estáveis. Eles permanecem desativados por segurança até as credenciais/provedores serem configurados.'
