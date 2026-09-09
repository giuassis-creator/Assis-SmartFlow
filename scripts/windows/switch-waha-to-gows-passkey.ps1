$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

function Read-EnvValue([string]$Name) {
  $line = Get-Content .env | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -Last 1
  if (-not $line) { return $null }
  $value = ($line -split '=',2)[1].Trim()
  if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) { $value = $value.Substring(1,$value.Length-2) }
  return $value
}
function Set-EnvValue([string]$Name,[string]$Value) {
  $lines = @(Get-Content .env)
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  $found = $false
  for ($i=0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $pattern) { $lines[$i] = "$Name=$Value"; $found=$true } }
  if (-not $found) { $lines += "$Name=$Value" }
  Set-Content .env -Value $lines -Encoding utf8
}
if (-not (Test-Path .env)) { throw '.env não encontrado.' }
$version=Read-EnvValue 'WAHA_VERSION'; if ([string]::IsNullOrWhiteSpace($version)) {$version='2026.8.2';Set-EnvValue 'WAHA_VERSION' $version}
$session=Read-EnvValue 'WAHA_SESSION'; if ([string]::IsNullOrWhiteSpace($session)) {$session='default';Set-EnvValue 'WAHA_SESSION' $session}
$apiKey=Read-EnvValue 'WAHA_API_KEY'; if ([string]::IsNullOrWhiteSpace($apiKey)) {throw 'WAHA_API_KEY não encontrado.'}

Write-Host '=== Assis SmartFlow - retorno controlado WAHA/GOWS ==='
Write-Host 'INFO: nenhum volume, organização ou memória será removido.'
Set-EnvValue 'WAHA_ENGINE' 'GOWS'
Set-EnvValue 'WAHA_IMAGE_TAG' "gows-$version"
$compose=@('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml','-f','core/docker-compose.waha-setup.yml')
& docker pull "devlikeapro/waha:gows-$version" | Out-Host
if ($LASTEXITCODE -ne 0) {throw 'Falha ao baixar WAHA/GOWS.'}
& docker compose @compose up -d --no-deps --force-recreate waha | Out-Host
if ($LASTEXITCODE -ne 0) {throw 'Falha ao recriar WAHA/GOWS.'}
$headers=@{'X-Api-Key'=$apiKey;Accept='application/json'}
$deadline=(Get-Date).AddSeconds(120)
do {try {$r=Invoke-WebRequest -Uri 'http://127.0.0.1:3000/api/sessions' -Headers $headers -SkipHttpErrorCheck -TimeoutSec 5;if($r.StatusCode -eq 200){break}}catch{};Start-Sleep 3} while((Get-Date)-lt $deadline)
if((Get-Date)-ge $deadline){throw 'WAHA/GOWS não ficou saudável.'}

# First re-run SmartFlow publication/auth/lifecycle gates. It may generate a QR, but this script does not require scanning it.
& "$PSScriptRoot\continue-waha-homologation.ps1"
if ($LASTEXITCODE -ne 0) {exit $LASTEXITCODE}

$state=Invoke-RestMethod -Uri ("http://127.0.0.1:3000/api/sessions/{0}" -f [uri]::EscapeDataString($session)) -Headers $headers -TimeoutSec 10
Write-Host "PASS: engine=$($state.engine.engine) status=$($state.status)"
Write-Host ''
Write-Host 'PRÓXIMO PASSO: solicite o código de pareamento sem QR informando o número controlado.'
Write-Host 'Execute:'
Write-Host '.\scripts\windows\request-waha-pairing-code.ps1 -PhoneNumber 5511999999999'
Write-Host 'Substitua pelo número WhatsApp autorizado, em formato internacional, somente dígitos.'
