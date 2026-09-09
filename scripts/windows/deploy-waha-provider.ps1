$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml','-f','core/docker-compose.waha-setup.yml')
$workflowPaths = @(
  'library/agents/11-internal-auth-verify.json',
  'library/workflows/01-canonical-ingress.json',
  'library/agents/09-tool-policy-gateway.json',
  'starter/workflows/06-outbound-text.json',
  'starter/workflows/08-waha-inbound.json'
)
$workflowNames = @(
  'Internal Auth Verify',
  '01 Canonical Ingress',
  'Internal Tool Policy Gateway',
  'Starter 06 Outbound Text',
  'Starter 08 WAHA Inbound'
)

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}." }
  $id = (($out | Where-Object { $_ }) -join '').Trim()
  if ($id -and $id -notmatch '^[0-9a-f]{12,64}$') { throw "Docker retornou identificador inesperado para ${Service}." }
  return $id
}

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
  for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $pattern) { $lines[$i] = "$Name=$Value"; $found = $true }
  }
  if (-not $found) { $lines += "$Name=$Value" }
  Set-Content .env -Value $lines -Encoding utf8
}

function New-RandomHex([int]$Bytes=32) {
  $buffer = New-Object byte[] $Bytes
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
  return -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

function Get-Sha256Hex([string]$Value) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value)) } finally { $sha.Dispose() }
  return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

function Invoke-PgScalar([string]$Sql) {
  $postgres = Get-ComposeContainer 'postgres'
  if (-not $postgres) { throw 'Container PostgreSQL não encontrado.' }
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Invoke-N8nPost([string]$Path,[string]$Token,[string]$JsonBody) {
  $n8n = Get-ComposeContainer 'n8n'
  if (-not $n8n) { throw 'Container n8n não encontrado.' }
  $script = @'
const path=process.env.ASSIS_PATH;
const token=process.env.ASSIS_TOKEN;
const body=process.env.ASSIS_BODY;
fetch('http://127.0.0.1:5678'+path,{method:'POST',headers:{'content-type':'application/json','x-assis-internal-token':token},body})
 .then(async r=>console.log(String(r.status)+'|'+await r.text()))
 .catch(e=>{console.error(e);process.exit(2);});
'@
  $out = & docker exec --env "ASSIS_PATH=$Path" --env "ASSIS_TOKEN=$Token" --env "ASSIS_BODY=$JsonBody" $n8n node -e $script 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao chamar n8n internamente:`n$($out -join "`n")" }
  return (($out | Where-Object { $_ }) -join "`n").Trim()
}

function Wait-N8nWebhook([string]$Path,[int]$TimeoutSeconds=120) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $n8n = Get-ComposeContainer 'n8n'
    if ($n8n) {
      $probe = & docker exec $n8n node -e "fetch('http://127.0.0.1:5678$Path',{method:'POST',headers:{'content-type':'application/json'},body:'{}'}).then(r=>console.log(r.status)).catch(()=>process.exit(2))" 2>$null
      if ($LASTEXITCODE -eq 0) {
        $status = (($probe | Where-Object { $_ }) -join '').Trim()
        if ($status -and $status -ne '404') { Write-Host "PASS: rota $Path registrada (probe HTTP $status)."; return }
      }
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  throw "Webhook '$Path' não foi registrado em até ${TimeoutSeconds}s."
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }
Write-Host '=== Assis SmartFlow WAHA Community - Multi-tenant WhatsApp Provider ==='

Write-Host '1/8 Preparando configuração WAHA segura...'
$apiKey = Read-EnvValue 'WAHA_API_KEY'
if ([string]::IsNullOrWhiteSpace($apiKey) -or $apiKey -match '^CHANGE_ME') { $apiKey = New-RandomHex 32; Set-EnvValue 'WAHA_API_KEY' $apiKey }
$webhookSecret = Read-EnvValue 'WAHA_WEBHOOK_SECRET'
if ([string]::IsNullOrWhiteSpace($webhookSecret) -or $webhookSecret -match '^CHANGE_ME') { $webhookSecret = New-RandomHex 32; Set-EnvValue 'WAHA_WEBHOOK_SECRET' $webhookSecret }
$dashboardPassword = Read-EnvValue 'WAHA_DASHBOARD_PASSWORD'
if ([string]::IsNullOrWhiteSpace($dashboardPassword) -or $dashboardPassword -match '^CHANGE_ME') { $dashboardPassword = New-RandomHex 24; Set-EnvValue 'WAHA_DASHBOARD_PASSWORD' $dashboardPassword }
$session = Read-EnvValue 'WAHA_SESSION'; if ([string]::IsNullOrWhiteSpace($session)) { $session='default'; Set-EnvValue 'WAHA_SESSION' $session }
Set-EnvValue 'WHATSAPP_PROVIDER_DEFAULT' 'waha'
$env:WAHA_API_KEY=$apiKey
$env:WAHA_WEBHOOK_SECRET=$webhookSecret
$env:WAHA_DASHBOARD_PASSWORD=$dashboardPassword
$env:WAHA_SESSION=$session
$env:WHATSAPP_PROVIDER_DEFAULT='waha'
Write-Host "PASS: segredos WAHA gerados/preservados localmente; sessão=$session. Nenhum segredo foi exibido."

Write-Host '2/8 Aplicando registry multi-tenant e hash escopado do webhook...'
$migration = Get-Content -Raw 'core/db/migrations/007_whatsapp_provider_registry.sql'
Invoke-PgScalar $migration | Out-Null
$hash = Get-Sha256Hex $webhookSecret
Invoke-PgScalar "INSERT INTO internal_auth_secrets(name,token_sha256,updated_at) VALUES('waha-webhook','$hash',now()) ON CONFLICT(name) DO UPDATE SET token_sha256=EXCLUDED.token_sha256,updated_at=now();" | Out-Null
$orgSlug = Read-EnvValue 'WAHA_ORGANIZATION_SLUG'
if ([string]::IsNullOrWhiteSpace($orgSlug)) {
  $orgSlug = Invoke-PgScalar "SELECT slug FROM organizations WHERE slug='default' UNION ALL SELECT slug FROM organizations WHERE slug<>'default' ORDER BY slug LIMIT 1;"
  if ([string]::IsNullOrWhiteSpace($orgSlug)) { throw 'Nenhuma organização existente foi encontrada para vincular à sessão WAHA.' }
  Set-EnvValue 'WAHA_ORGANIZATION_SLUG' $orgSlug
}
$orgEsc = $orgSlug.Replace("'","''")
$sessionEsc = $session.Replace("'","''")
$route = Invoke-PgScalar "WITH org AS (SELECT id FROM organizations WHERE slug='$orgEsc' LIMIT 1) INSERT INTO organization_whatsapp_providers(organization_id,provider,session_name,priority,enabled,config,updated_at) SELECT id,'waha','$sessionEsc',1,true,'{}'::jsonb,now() FROM org ON CONFLICT(organization_id,provider,session_name) DO UPDATE SET priority=1,enabled=true,updated_at=now() RETURNING organization_id::text;"
if ([string]::IsNullOrWhiteSpace($route)) { throw "Organização '$orgSlug' não encontrada para vincular WAHA." }
Write-Host "PASS: sessão WAHA '$session' vinculada à organização '$orgSlug' sem segredo no registry."

Write-Host '3/8 Iniciando WAHA Community e provider-gateway isolado...'
& docker compose @compose pull waha | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao baixar imagem WAHA.' }
& docker compose @compose build provider-gateway | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir provider-gateway.' }
& docker compose @compose up -d --no-deps --force-recreate waha provider-gateway | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao iniciar WAHA/provider-gateway.' }
$headers = @{'X-Api-Key'=$apiKey;Accept='application/json'}
$deadline=(Get-Date).AddSeconds(150)
do {
  try { $r=Invoke-WebRequest -Uri 'http://127.0.0.1:3000/api/sessions' -Headers $headers -SkipHttpErrorCheck -TimeoutSec 5; if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { break } } catch {}
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ((Get-Date) -ge $deadline) { $waha=Get-ComposeContainer 'waha'; if($waha){& docker logs --tail 160 $waha 2>&1|Out-Host}; throw 'WAHA não ficou saudável em até 150s.' }
$n8n=Get-ComposeContainer 'n8n'
$exposure=& docker exec $n8n sh -lc 'if [ -n "${WAHA_API_KEY:-}" ] || [ -n "${WAHA_WEBHOOK_SECRET:-}" ]; then echo PRESENT; else echo ABSENT; fi' 2>&1
if (($exposure -join '').Trim() -ne 'ABSENT') { throw 'Segredos WAHA foram expostos ao processo n8n.' }
Write-Host 'PASS: WAHA saudável em loopback; segredos ausentes do processo n8n.'

Write-Host '4/8 Importando workflows WAHA e roteamento multi-provider...'
& "$PSScriptRoot\import-workflows.ps1" -Force -Only $workflowPaths
& "$PSScriptRoot\bind-postgres-workflow-credentials.ps1"

Write-Host '5/8 Publicando workflows e aguardando rotas...'
$n8n=Get-ComposeContainer 'n8n'
foreach($name in $workflowNames){
  $escaped=$name.Replace("'","''")
  $id=Invoke-PgScalar "SELECT id FROM workflow_entity WHERE name='$escaped' ORDER BY \"updatedAt\" DESC LIMIT 1;"
  if([string]::IsNullOrWhiteSpace($id)){throw "Workflow '$name' não localizado."}
  $publish=& docker exec -u node $n8n n8n publish:workflow --id=$id 2>&1
  if($LASTEXITCODE -ne 0 -or (($publish -join "`n") -match '(?i)error|failed|not found')){throw "Falha ao publicar '$name':`n$($publish -join "`n")"}
  Write-Host "  PASS: $name publicado."
}
& docker compose @compose restart n8n | Out-Host
if($LASTEXITCODE -ne 0){throw 'Falha ao reiniciar n8n.'}
Wait-N8nWebhook '/webhook/adapter/waha/in' 120
Wait-N8nWebhook '/webhook/assis/internal/message/send-text' 120

Write-Host '6/8 Executando contratos estáticos...'
& docker compose @compose --profile tools build qa | Out-Host
if($LASTEXITCODE -ne 0){throw 'Falha ao construir QA.'}
& docker compose @compose --profile tools run --rm qa pytest -q tests/test_waha_provider.py tests/test_evolution_outbound.py tests/test_no_workflow_env_access.py -p no:cacheprovider | Out-Host
if($LASTEXITCODE -ne 0){throw 'Falha nos contratos do provider WhatsApp.'}

Write-Host '7/8 Criando/iniciando sessão WAHA idempotentemente...'
$sessionUrl='http://127.0.0.1:3000/api/sessions/'+[uri]::EscapeDataString($session)
$existing=Invoke-WebRequest -Uri $sessionUrl -Headers $headers -SkipHttpErrorCheck -TimeoutSec 10
if($existing.StatusCode -eq 404){
  $createHeaders=@{'X-Api-Key'=$apiKey;Accept='application/json';'Content-Type'='application/json'}
  $create=Invoke-WebRequest -Uri 'http://127.0.0.1:3000/api/sessions' -Headers $createHeaders -Method Post -Body (@{name=$session}|ConvertTo-Json -Compress) -SkipHttpErrorCheck -TimeoutSec 20
  if($create.StatusCode -lt 200 -or $create.StatusCode -ge 300){throw "Falha ao criar sessão WAHA (HTTP $($create.StatusCode))."}
}
Start-Sleep -Seconds 3
$state=Invoke-RestMethod -Uri $sessionUrl -Headers $headers -Method Get -TimeoutSec 10
if($state.status -eq 'STOPPED'){
  $startHeaders=@{'X-Api-Key'=$apiKey;Accept='application/json';'Content-Type'='application/json'}
  $start=Invoke-WebRequest -Uri "$sessionUrl/start" -Headers $startHeaders -Method Post -Body '{}' -SkipHttpErrorCheck -TimeoutSec 20
  if($start.StatusCode -lt 200 -or $start.StatusCode -ge 300){throw "Falha ao iniciar sessão WAHA (HTTP $($start.StatusCode))."}
  Start-Sleep -Seconds 4
  $state=Invoke-RestMethod -Uri $sessionUrl -Headers $headers -Method Get -TimeoutSec 10
}
Write-Host "Sessão WAHA: $session | status=$($state.status)"

Write-Host '8/8 Homologação funcional...'
if($state.status -ne 'WORKING'){
  $local=Join-Path $root '.local'; New-Item -ItemType Directory -Force -Path $local|Out-Null
  $qr=Join-Path $local 'waha-qr.png'
  try { Invoke-WebRequest -Uri ("http://127.0.0.1:3000/api/{0}/auth/qr" -f [uri]::EscapeDataString($session)) -Headers @{'X-Api-Key'=$apiKey;Accept='image/png'} -OutFile $qr -TimeoutSec 15; Write-Host "READY: sessão precisa ser pareada. QR salvo em: $qr" } catch { Write-Host 'READY: sessão precisa ser pareada; abra http://127.0.0.1:3000/dashboard e conecte usando a API key do seu .env.' }
  Write-Host 'Após escanear o QR e a sessão ficar WORKING, execute este mesmo script novamente para concluir a homologação E2E.'
  exit 0
}

$testNumber=Read-EnvValue 'WAHA_TEST_NUMBER'
if([string]::IsNullOrWhiteSpace($testNumber)){
  Write-Host 'PASS: sessão WAHA está WORKING e inbound/outbound estão implantados. WAHA_TEST_NUMBER vazio; nenhum envio real foi realizado.'
  exit 0
}
$internalToken=Read-EnvValue 'INTERNAL_AGENT_TOKEN'
if([string]::IsNullOrWhiteSpace($internalToken) -or $internalToken.Length -lt 32){throw 'INTERNAL_AGENT_TOKEN inválido para smoke E2E.'}
$marker=[guid]::NewGuid().ToString('N');$slug="waha-smoke-$marker";$idem="waha-smoke-$marker";$numEsc=$testNumber.Replace("'","''")
$ids=Invoke-PgScalar "WITH org AS (INSERT INTO organizations(slug,name,config) VALUES('$slug','WAHA Smoke','{\"smoke_test\":true}'::jsonb) RETURNING id),route AS (INSERT INTO organization_whatsapp_providers(organization_id,provider,session_name,priority,enabled) SELECT id,'waha','$sessionEsc',1,true FROM org),contact AS (INSERT INTO contacts(organization_id,external_id,name,phone) SELECT id,'$numEsc','WAHA Smoke','$numEsc' FROM org RETURNING id,organization_id),conv AS (INSERT INTO conversations(organization_id,contact_id,channel,external_id,last_message_at) SELECT organization_id,id,'whatsapp','$numEsc',now() FROM contact RETURNING id,organization_id) SELECT organization_id::text||'|'||id::text FROM conv;"
$parts=$ids -split '\|',2;if($parts.Count -ne 2){throw 'Falha ao criar contexto temporário de smoke WAHA.'};$orgId=$parts[0];$conversationId=$parts[1]
try{
  $body=@{organization_id=$orgId;conversation_id=$conversationId;idempotency_key=$idem;to=$testNumber;text="Homologação Assis SmartFlow WAHA $marker";channel='whatsapp'}|ConvertTo-Json -Compress
  $good=Invoke-N8nPost '/webhook/assis/internal/message/send-text' $internalToken $body
  $status=($good -split '\|',2)[0].Trim();if($status -ne '200'){throw "Outbound WAHA válido retornou HTTP $status."}
  Start-Sleep -Seconds 2
  $verify=Invoke-PgScalar "SELECT (SELECT count(*) FROM messages WHERE organization_id='$orgId'::uuid AND idempotency_key='$idem' AND direction='out')::text||'|'||(SELECT count(*) FROM tool_idempotency WHERE organization_id='$orgId'::uuid AND operation='message.send_text' AND idempotency_key='$idem' AND status='completed')::text;"
  if($verify -ne '1|1'){throw "Persistência/idempotência WAHA inesperada: $verify"}
  Write-Host 'PASS: WAHA outbound real enviado, persistido uma vez e idempotência concluída.'
}finally{try{Invoke-PgScalar "DELETE FROM organizations WHERE id='$orgId'::uuid;"|Out-Null}catch{Write-Warning 'Não foi possível limpar organização temporária.'}}
Write-Host ''
Write-Host 'PASS: WAHA Community implantado e homologado E2E como provider WhatsApp padrão.'
Write-Host 'Evolution permanece disponível como adapter legado opcional.'
