$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml','-f','core/docker-compose.waha-setup.yml')

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}." }
  $id = (($out | Where-Object { $_ }) -join '').Trim()
  if (-not $id) { throw "Container ${Service} não encontrado." }
  return $id
}

Write-Host '=== Assis SmartFlow WAHA - diagnóstico outbound ==='

$pgw = Get-ComposeContainer 'provider-gateway'
$n8n = Get-ComposeContainer 'n8n'
$waha = Get-ComposeContainer 'waha'

Write-Host '--- provider-gateway /healthz ---'
& docker exec $pgw python -c "import json,urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=10).read().decode())"

Write-Host '--- últimas linhas provider-gateway ---'
& docker logs --tail 120 $pgw 2>&1 | Select-String -Pattern 'WAHA|sendText|ERROR|Exception|Traceback|provider_status|401|403|404|422|500|502'

Write-Host '--- últimas linhas n8n relacionadas ao outbound ---'
& docker logs --tail 180 $n8n 2>&1 | Select-String -Pattern 'Outbound Text|Send via Provider Gateway|Error in workflow|message.send_text|provider-gateway|500|502'

Write-Host '--- últimas linhas WAHA relacionadas a envio ---'
& docker logs --tail 180 $waha 2>&1 | Select-String -Pattern 'sendText|error|ERROR|failed|FAILED|message'

Write-Host 'INFO: nenhum segredo foi impresso intencionalmente. Cole esta saída completa para análise.'
