$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$logDir = Join-Path $root '.local\monitoring'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'hourly-health.jsonl'
$checkedAt = (Get-Date).ToUniversalTime().ToString('o')
$failures = [System.Collections.Generic.List[string]]::new()

$required = @(
  'assis-smartflow-n8n-1',
  'assis-smartflow-postgres-1',
  'assis-smartflow-redis-1',
  'assis-smartflow-provider-gateway-1',
  'assis-smartflow-waha-1',
  'assis-smartflow-caddy-1'
)

$services = @()
foreach ($name in $required) {
  $raw = & docker inspect --format '{{json .State}}' $name 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) {
    $failures.Add("container_missing:$name")
    $services += [ordered]@{ name = $name; status = 'missing'; health = $null }
    continue
  }
  $state = $raw | ConvertFrom-Json
  $health = if ($state.Health) { [string]$state.Health.Status } else { $null }
  $services += [ordered]@{ name = $name; status = [string]$state.Status; health = $health }
  if ($state.Status -ne 'running') { $failures.Add("container_not_running:$name") }
  if ($health -and $health -ne 'healthy') { $failures.Add("container_unhealthy:$name") }
}

function Get-HttpCode([string]$Url) {
  $code = (& curl.exe -k -s -o NUL -w '%{http_code}' $Url 2>$null)
  if ($LASTEXITCODE -ne 0) { return '000' }
  return ([string]$code).Trim()
}

$n8nCode = Get-HttpCode 'https://assis.localhost/'
$internalCode = Get-HttpCode 'https://assis.localhost/webhook/assis/internal/auth/verify'
if ($n8nCode -ne '200') { $failures.Add("n8n_http:$n8nCode") }
if ($internalCode -ne '404') { $failures.Add("internal_route_http:$internalCode") }

$gatewayOk = $false
$gatewayRaw = & docker exec assis-smartflow-provider-gateway-1 python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=5).read().decode())" 2>$null
if ($LASTEXITCODE -eq 0 -and $gatewayRaw) {
  try { $gatewayOk = [bool](($gatewayRaw -join '') | ConvertFrom-Json).ok } catch { $gatewayOk = $false }
}
if (-not $gatewayOk) { $failures.Add('provider_gateway_health:false') }

$result = [ordered]@{
  checked_at_utc = $checkedAt
  ok = ($failures.Count -eq 0)
  n8n_http = $n8nCode
  internal_route_http = $internalCode
  provider_gateway_ok = $gatewayOk
  failures = @($failures)
  services = $services
}
($result | ConvertTo-Json -Depth 8 -Compress) | Add-Content -Path $logFile -Encoding utf8

if ($failures.Count -gt 0) {
  Write-Error ("Assis SmartFlow health check failed: " + ($failures -join ', '))
  exit 1
}
Write-Host "PASS: Assis SmartFlow saudável em $checkedAt"
