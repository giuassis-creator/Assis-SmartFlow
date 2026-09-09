param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[0-9]{8,15}$')]
  [string]$PhoneNumber
)

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

function Get-State([string]$SessionUrl,[hashtable]$Headers) {
  return Invoke-RestMethod -Uri $SessionUrl -Headers $Headers -Method Get -TimeoutSec 10
}

function Invoke-SessionAction([string]$SessionUrl,[hashtable]$Headers,[string]$Action) {
  $url = "$SessionUrl/$Action"
  $response = Invoke-WebRequest -Uri $url -Headers $Headers -Method Post -Body '{}' -SkipHttpErrorCheck -TimeoutSec 30
  if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
    throw "Falha em '$Action' (HTTP $($response.StatusCode)): $($response.Content)"
  }
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }
$session = Read-EnvValue 'WAHA_SESSION'
if ([string]::IsNullOrWhiteSpace($session)) { $session = 'default' }
$apiKey = Read-EnvValue 'WAHA_API_KEY'
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'WAHA_API_KEY não encontrado.' }

$headers = @{'X-Api-Key'=$apiKey;Accept='application/json';'Content-Type'='application/json'}
$sessionUrl = 'http://127.0.0.1:3000/api/sessions/' + [uri]::EscapeDataString($session)
$state = Get-State $sessionUrl $headers

Write-Host "Engine atual: $($state.engine.engine) | status=$($state.status)"
if ($state.engine.engine -ne 'GOWS') { throw "Este fluxo exige GOWS; engine atual=$($state.engine.engine)." }
if ($state.status -eq 'WORKING') { Write-Host 'PASS: sessão já está WORKING.'; exit 0 }

if ($state.status -eq 'FAILED') {
  Write-Host "RECOVERY: sessão '$session' está FAILED; reiniciando sem logout e sem remover volumes..."
  Invoke-SessionAction $sessionUrl $headers 'restart'
}

$deadline = (Get-Date).AddSeconds(90)
$last = $null
do {
  Start-Sleep -Seconds 1
  $state = Get-State $sessionUrl $headers
  if ($state.status -ne $last) {
    Write-Host "Estado: $($state.status)"
    $last = $state.status
  }
  if ($state.status -in @('SCAN_QR_CODE','WORKING','PASSKEY_REQUIRED','PASSKEY_CONFIRMATION_REQUIRED')) { break }
} while ((Get-Date) -lt $deadline)

if ($state.status -eq 'WORKING') { Write-Host 'PASS: sessão ficou WORKING.'; exit 0 }
if ($state.status -eq 'PASSKEY_REQUIRED') { Write-Host 'READY: PASSKEY_REQUIRED.'; exit 0 }
if ($state.status -eq 'PASSKEY_CONFIRMATION_REQUIRED') { Write-Host 'READY: PASSKEY_CONFIRMATION_REQUIRED.'; exit 0 }
if ($state.status -ne 'SCAN_QR_CODE') {
  Write-Host "ERRO: sessão não voltou a SCAN_QR_CODE; estado final=$($state.status)."
  Write-Host 'Nenhum logout, purge ou remoção de volume foi executado.'
  exit 2
}

Write-Host 'PASS: sessão pronta para solicitar pairing code.'
$url = 'http://127.0.0.1:3000/api/' + [uri]::EscapeDataString($session) + '/auth/request-code'
$body = @{phoneNumber=$PhoneNumber} | ConvertTo-Json -Compress
$response = Invoke-WebRequest -Uri $url -Headers $headers -Method Post -Body $body -SkipHttpErrorCheck -TimeoutSec 30
if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
  throw "Falha ao solicitar código (HTTP $($response.StatusCode)): $($response.Content)"
}

Write-Host '=== CÓDIGO DE PAREAMENTO WAHA/GOWS ==='
try {
  $obj = $response.Content | ConvertFrom-Json
  $code = $obj.code
  if (-not $code) { $code = $obj.pairingCode }
  if ($code) { Write-Host "Código: $code" } else { Write-Host $response.Content }
} catch {
  Write-Host $response.Content
}

Write-Host 'No WhatsApp: Dispositivos conectados > Conectar um dispositivo > Conectar com número de telefone.'
Write-Host 'Aguardando o resultado por até 120 segundos...'
$deadline = (Get-Date).AddSeconds(120)
$last = $null
do {
  Start-Sleep -Seconds 2
  $state = Get-State $sessionUrl $headers
  if ($state.status -ne $last) {
    Write-Host "Estado: $($state.status)"
    $last = $state.status
  }
  if ($state.status -in @('WORKING','PASSKEY_REQUIRED','PASSKEY_CONFIRMATION_REQUIRED','FAILED')) { break }
} while ((Get-Date) -lt $deadline)

switch ($state.status) {
  'WORKING' { Write-Host 'PASS: sessão WAHA está WORKING.'; exit 0 }
  'PASSKEY_REQUIRED' { Write-Host 'READY: WhatsApp exige PASSKEY_REQUIRED.'; exit 0 }
  'PASSKEY_CONFIRMATION_REQUIRED' { Write-Host 'READY: WhatsApp exige PASSKEY_CONFIRMATION_REQUIRED.'; exit 0 }
  'FAILED' { Write-Host 'FAILED: pareamento foi recusado. Não repita automaticamente; preserve os logs.'; exit 3 }
  default { Write-Host "INFO: estado final=$($state.status). Nenhum dado foi removido."; exit 4 }
}
