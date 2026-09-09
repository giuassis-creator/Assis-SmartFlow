$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

function Read-EnvValue([string]$Name) {
  $line = Get-Content .env | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -Last 1
  if (-not $line) { return $null }
  $value = ($line -split '=',2)[1].Trim()
  if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
    $value = $value.Substring(1,$value.Length-2)
  }
  return $value
}

function Set-EnvValue([string]$Name,[string]$Value) {
  $lines = @(Get-Content .env)
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  $found = $false
  for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $pattern) {
      $lines[$i] = "$Name=$Value"
      $found = $true
    }
  }
  if (-not $found) { $lines += "$Name=$Value" }
  Set-Content .env -Value $lines -Encoding utf8
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }

$version = Read-EnvValue 'WAHA_VERSION'
if ([string]::IsNullOrWhiteSpace($version)) { $version = '2026.8.2'; Set-EnvValue 'WAHA_VERSION' $version }
$session = Read-EnvValue 'WAHA_SESSION'
if ([string]::IsNullOrWhiteSpace($session)) { $session = 'default'; Set-EnvValue 'WAHA_SESSION' $session }

Write-Host '=== Assis SmartFlow - fallback de pareamento WAHA NOWEB ==='
Write-Host "INFO: preservando volumes e dados; apenas a engine WAHA será alterada para NOWEB para a sessão '$session'."
Write-Host 'INFO: GOWS e NOWEB usam namespaces de sessão distintos por padrão; nenhum logout/remoção do volume GOWS será executado.'

Set-EnvValue 'WAHA_ENGINE' 'NOWEB'
Set-EnvValue 'WAHA_IMAGE_TAG' "noweb-$version"

$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml','-f','core/docker-compose.waha-setup.yml')
& docker pull "devlikeapro/waha:noweb-$version" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Falha ao baixar devlikeapro/waha:noweb-$version." }

& docker compose @compose up -d --no-deps --force-recreate waha | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar somente o serviço WAHA com NOWEB.' }

$apiKey = Read-EnvValue 'WAHA_API_KEY'
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'WAHA_API_KEY não encontrado no .env.' }
$headers = @{'X-Api-Key'=$apiKey;Accept='application/json'}
$deadline = (Get-Date).AddSeconds(120)
do {
  try {
    $sessions = Invoke-WebRequest -Uri 'http://127.0.0.1:3000/api/sessions' -Headers $headers -SkipHttpErrorCheck -TimeoutSec 5
    if ($sessions.StatusCode -ge 200 -and $sessions.StatusCode -lt 300) { break }
  } catch {}
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ((Get-Date) -ge $deadline) { throw 'WAHA/NOWEB não ficou saudável em até 120s.' }

Write-Host 'PASS: WAHA/NOWEB saudável. Iniciando homologação/pairing pela mesma cadeia SmartFlow...'
& "$PSScriptRoot\continue-waha-homologation.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
