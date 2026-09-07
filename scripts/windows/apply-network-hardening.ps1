$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

function Get-ServiceContainer([string]$Service) {
  $containerId = ((& docker compose @compose ps -q $Service 2>&1 | Where-Object { $_ }) -join '').Trim()
  return $containerId
}

Write-Host 'Aplicando hardening de rede sem remover volumes e sem reiniciar serviços já endurecidos...'
$internalServices = @('n8n','ollama','qdrant','stt','tts')
$needsRecreate = @()
foreach ($service in $internalServices) {
  $containerId = Get-ServiceContainer $service
  if (-not $containerId) {
    $needsRecreate += $service
    continue
  }
  $published = (& docker port $containerId 2>&1 | Where-Object { $_ }) -join "`n"
  if (-not [string]::IsNullOrWhiteSpace($published)) {
    $needsRecreate += $service
  }
}

if ($needsRecreate.Count -gt 0) {
  Write-Host "Removendo bindings de host apenas de: $($needsRecreate -join ', ')"
  & docker compose @compose up -d --force-recreate --no-deps @needsRecreate | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar containers que ainda possuíam portas publicadas.' }
} else {
  Write-Host 'PASS: serviços internos já estavam endurecidos; nenhum restart desnecessário foi feito.'
}

foreach ($service in $internalServices) {
  $containerId = Get-ServiceContainer $service
  if (-not $containerId) { throw "Container do serviço $service não está em execução." }
  $published = (& docker port $containerId 2>&1 | Where-Object { $_ }) -join "`n"
  if (-not [string]::IsNullOrWhiteSpace($published)) {
    throw "Serviço interno $service ainda possui porta publicada no host:`n$published"
  }
  Write-Host "PASS: $service sem porta publicada no host."
}

$caddyId = Get-ServiceContainer 'caddy'
if (-not $caddyId) {
  & docker compose @compose up -d --no-deps caddy | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao iniciar o Caddy.' }
  $caddyId = Get-ServiceContainer 'caddy'
}
if (-not $caddyId) { throw 'Container caddy não está em execução.' }

& docker exec $caddyId caddy validate --config /etc/caddy/Caddyfile | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Caddyfile inválido após hardening.' }
& docker exec $caddyId caddy reload --config /etc/caddy/Caddyfile | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recarregar o Caddyfile endurecido.' }

$deadline = (Get-Date).AddSeconds(60)
$statusCode = ''
do {
  try {
    $statusCode = (& curl.exe -k -s -o NUL -w "%{http_code}" https://assis.localhost/webhook/assis/internal/auth/verify 2>$null).Trim()
  } catch {
    $statusCode = ''
  }
  if ($statusCode -eq '404') { break }
  Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

if ($statusCode -ne '404') {
  throw "Proxy público não bloqueou rota interna como esperado. HTTP observado: '$statusCode'."
}

Write-Host 'PASS: Caddy bloqueia /webhook/assis/internal/* externamente com HTTP 404.'
Write-Host 'PASS: hardening de rede aplicado; apenas Caddy permanece publicado no host.'
