param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$markerDir = Join-Path $root '.local'
$marker = Join-Path $markerDir 'workflow-import-v1.done'
if ((Test-Path $marker) -and -not $Force) {
  Write-Host 'Workflows já importados neste clone. Use -Force apenas se você souber que deseja reimportá-los.'
  exit 0
}
New-Item -ItemType Directory -Force -Path $markerDir | Out-Null

$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$imports = @(
  @{ Host = 'library/agents';          Container = '/opt/assis/library/agents' },
  @{ Host = 'library/workflows';       Container = '/opt/assis/library/workflows' },
  @{ Host = 'starter/workflows';       Container = '/opt/assis/starter/workflows' },
  @{ Host = 'professional/workflows';  Container = '/opt/assis/professional/workflows' },
  @{ Host = 'enterprise/workflows';    Container = '/opt/assis/enterprise/workflows' }
)

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
    $containerFile = "$($entry.Container)/$($file.Name)"
    Write-Host "  -> $containerFile"
    & docker compose @compose exec -T n8n n8n import:workflow "--input=$containerFile"
    if ($LASTEXITCODE -ne 0) {
      throw "Falha ao importar workflow: $containerFile"
    }
  }
}

Set-Content -Path $marker -Value (Get-Date).ToString('o') -Encoding ascii
Write-Host 'Workflows importados. Eles permanecem desativados por segurança até as credenciais/provedores serem configurados.'
