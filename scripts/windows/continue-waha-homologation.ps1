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

function Get-ComposeContainer([string]$Service) {
  $compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
  $out = & docker compose @compose ps -q $Service 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}." }
  $id = (($out | Where-Object { $_ }) -join '').Trim()
  if (-not $id -or $id -notmatch '^[0-9a-f]{12,64}$') { throw "Container ${Service} não encontrado." }
  return $id
}

function Get-WahaSession([string]$Session,[hashtable]$Headers) {
  $url = 'http://127.0.0.1:3000/api/sessions/' + [uri]::EscapeDataString($Session)
  return Invoke-RestMethod -Uri $url -Headers $Headers -Method Get -TimeoutSec 10
}

function Restart-WahaSession([string]$Session,[hashtable]$Headers) {
  $url = 'http://127.0.0.1:3000/api/sessions/' + [uri]::EscapeDataString($Session) + '/restart'
  $response = Invoke-WebRequest -Uri $url -Headers ($Headers + @{'Content-Type'='application/json'}) -Method Post -Body '{}' -SkipHttpErrorCheck -TimeoutSec 20
  if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
    throw "Falha ao reiniciar sessão WAHA '$Session' (HTTP $($response.StatusCode))."
  }
}

function Invoke-PgScalar([string]$Sql) {
  $postgres = Get-ComposeContainer 'postgres'
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Test-WahaLifecycleWebhook([string]$Secret,[string]$Session) {
  $n8n = Get-ComposeContainer 'n8n'
  $body = @{event='session.status';session=$Session;payload=@{status='SCAN_QR_CODE'}} | ConvertTo-Json -Depth 5 -Compress
  $script = @'
const secret=process.env.ASSIS_SECRET;
const body=process.env.ASSIS_BODY;
fetch('http://127.0.0.1:5678/webhook/adapter/waha/in',{
  method:'POST',
  headers:{'content-type':'application/json','x-assis-secret':secret},
  body
}).then(async r=>console.log(String(r.status)+'|'+await r.text())).catch(e=>{console.error(e);process.exit(2);});
'@
  $out = & docker exec --env "ASSIS_SECRET=$Secret" --env "ASSIS_BODY=$body" $n8n node -e $script 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao testar webhook WAHA:`n$($out -join "`n")" }
  $text = (($out | Where-Object { $_ }) -join "`n").Trim()
  $status = ($text -split '\|',2)[0].Trim()
  if ($status -ne '200') { throw "Webhook WAHA lifecycle retornou HTTP ${status}: $text" }
  Write-Host 'PASS: webhook WAHA lifecycle autenticado responde HTTP 200 sem encaminhar evento não-mensagem.'
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }

$session = Read-EnvValue 'WAHA_SESSION'
if ([string]::IsNullOrWhiteSpace($session)) { $session = 'default'; Set-EnvValue 'WAHA_SESSION' $session }
$orgName = Read-EnvValue 'ORG_NAME'
if ([string]::IsNullOrWhiteSpace($orgName)) { $orgName = 'Minha Empresa' }

$currentSlug = Read-EnvValue 'WAHA_ORGANIZATION_SLUG'
$mustRepair = [string]::IsNullOrWhiteSpace($currentSlug) -or $currentSlug -match '(?i)(^|[-_])smoke([-_]|$)' -or $currentSlug -match '(?i)^evolution-smoke-'
if ($mustRepair) {
  Set-EnvValue 'WAHA_ORGANIZATION_SLUG' 'default'
  Write-Host "REPAIR: WAHA_ORGANIZATION_SLUG alterado de tenant temporário para 'default'."
} elseif ($currentSlug -ne 'default') {
  Write-Host "INFO: WAHA_ORGANIZATION_SLUG='$currentSlug' foi definido explicitamente e será preservado."
}

$postgres = Get-ComposeContainer 'postgres'
$sessionEsc = $session.Replace("'","''")
$nameEsc = $orgName.Replace("'","''")
$sql = @"
BEGIN;
INSERT INTO organizations(slug,name,config)
VALUES('default','$nameEsc','{}'::jsonb)
ON CONFLICT(slug) DO NOTHING;

DELETE FROM organization_whatsapp_providers p
USING organizations o
WHERE p.organization_id=o.id
  AND p.provider='waha'
  AND p.session_name='$sessionEsc'
  AND o.slug<>'default';

INSERT INTO organization_whatsapp_providers(organization_id,provider,session_name,priority,enabled,config,updated_at)
SELECT id,'waha','$sessionEsc',1,true,'{}'::jsonb,now()
FROM organizations
WHERE slug='default'
ON CONFLICT(organization_id,provider,session_name)
DO UPDATE SET priority=1,enabled=true,updated_at=now();
COMMIT;

SELECT o.slug||'|'||p.provider||'|'||p.session_name||'|'||p.enabled::text
FROM organization_whatsapp_providers p
JOIN organizations o ON o.id=p.organization_id
WHERE p.provider='waha' AND p.session_name='$sessionEsc'
ORDER BY p.priority,o.slug;
"@

$out = & docker exec --env "ASSIS_SQL=$sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
$route = (($out | Where-Object { $_ -match '^default\|waha\|' }) -join '').Trim()
if (-not $route) { throw 'Falha ao validar o vínculo WAHA da organização default.' }
Write-Host "PASS: sessão WAHA '$session' pertence somente à organização 'default'."
Write-Host 'PASS: tenant temporário não será usado no pareamento WhatsApp.'

& "$PSScriptRoot\deploy-waha-provider.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Pairing is blocked until the public WAHA adapter has a real active n8n version
# and can acknowledge lifecycle events. This prevents another QR attempt while the
# provider is posting into a stale/non-active workflow snapshot.
$activeSql = @"
SELECT count(*)
FROM workflow_entity
WHERE name='Starter 08 WAHA Inbound'
  AND "activeVersionId" IS NOT NULL;
"@
$activeCount = Invoke-PgScalar $activeSql
if ($activeCount -ne '1') { throw "Starter 08 WAHA Inbound não possui exatamente uma versão ativa (count=$activeCount). Pareamento bloqueado." }
Write-Host 'PASS: Starter 08 WAHA Inbound possui activeVersionId.'
$webhookSecret = Read-EnvValue 'WAHA_WEBHOOK_SECRET'
if ([string]::IsNullOrWhiteSpace($webhookSecret)) { throw 'WAHA_WEBHOOK_SECRET não encontrado no .env.' }
Test-WahaLifecycleWebhook $webhookSecret $session

$apiKey = Read-EnvValue 'WAHA_API_KEY'
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'WAHA_API_KEY não encontrado no .env.' }
$headers = @{'X-Api-Key'=$apiKey;Accept='application/json'}
$state = Get-WahaSession $session $headers
if ($state.status -eq 'FAILED') {
  Write-Host "RECOVERY: sessão WAHA '$session' entrou em FAILED; reiniciando para gerar novo ciclo de QR..."
  Restart-WahaSession $session $headers
  $deadline = (Get-Date).AddSeconds(45)
  do {
    Start-Sleep -Seconds 2
    $state = Get-WahaSession $session $headers
    if ($state.status -in @('SCAN_QR_CODE','WORKING','PASSKEY_REQUIRED','PASSKEY_CONFIRMATION_REQUIRED')) { break }
  } while ((Get-Date) -lt $deadline)
}

Write-Host "Estado WAHA pós-recuperação: $($state.status)"
if ($state.status -eq 'SCAN_QR_CODE') {
  $local = Join-Path $root '.local'
  New-Item -ItemType Directory -Force -Path $local | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $qr = Join-Path $local "waha-qr-$stamp.png"
  $qrUrl = 'http://127.0.0.1:3000/api/' + [uri]::EscapeDataString($session) + '/auth/qr'
  Invoke-WebRequest -Uri $qrUrl -Headers @{'X-Api-Key'=$apiKey;Accept='image/png'} -OutFile $qr -TimeoutSec 15
  Set-Content -Path (Join-Path $local 'waha-qr-latest.txt') -Value $qr -Encoding utf8
  Write-Host "READY: QR WAHA renovado e salvo em: $qr"
  Write-Host "INFO: caminho do QR atual também registrado em: $(Join-Path $local 'waha-qr-latest.txt')"
  Write-Host 'Escaneie o QR imediatamente; ele expira e é renovado periodicamente pelo WhatsApp.'
} elseif ($state.status -eq 'WORKING') {
  Write-Host 'PASS: sessão WAHA está WORKING.'
} elseif ($state.status -in @('PASSKEY_REQUIRED','PASSKEY_CONFIRMATION_REQUIRED')) {
  Write-Host "READY: WAHA exige etapa adicional de passkey ($($state.status)); use o dashboard local para concluir o pareamento."
} else {
  $waha = Get-ComposeContainer 'waha'
  Write-Host '--- logs WAHA (últimas 120 linhas) ---'
  & docker logs --tail 120 $waha 2>&1 | Out-Host
  throw "Sessão WAHA permaneceu em estado '$($state.status)' após recuperação."
}
