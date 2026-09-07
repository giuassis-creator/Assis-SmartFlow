$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

Write-Host 'Aplicando hardening de rede sem remover volumes e sem reiniciar dependências persistentes...'
# IMPORTANT: do not let Compose recreate/restart postgres/redis as dependencies here.
# The hardening changes only host port bindings for these application services and Caddy.
$services = @('n8n','ollama','qdrant','stt','tts','caddy')
& docker compose @compose up -d --force-recreate --no-deps @services | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar containers para aplicar o hardening de rede.' }

$internalServices = @('n8n','ollama','qdrant','stt','tts')
foreach ($service in $internalServices) {
  $containerId = ((& docker compose @compose ps -q $service 2>&1 | Where-Object { $_ }) -join '').Trim()
  if (-not $containerId) { throw "Container do serviço $service não está em execução." }
  $published = (& docker port $containerId 2>&1 | Where-Object { $_ }) -join "`n"
  if (-not [string]::IsNullOrWhiteSpace($published)) {
    throw "Serviço interno $service ainda possui porta publicada no host:`n$published"
  }
  Write-Host "PASS: $service sem porta publicada no host."
}

$caddyId = ((& docker compose @compose ps -q caddy 2>&1 | Where-Object { $_ }) -join '').Trim()
if (-not $caddyId) { throw 'Container caddy não está em execução.' }
& docker exec $caddyId caddy validate --config /etc/caddy/Caddyfile | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Caddyfile inválido após hardening.' }

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
