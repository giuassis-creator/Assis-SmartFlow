$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$workflowPaths = @(
  'library/agents/09-tool-policy-gateway.json',
  'starter/workflows/06-outbound-text.json'
)
$workflowNames = @(
  'Internal Tool Policy Gateway',
  'Starter 06 Outbound Text'
)

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}:`n$($out -join "`n")" }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Read-EnvValue([string]$Name) {
  $line = Get-Content .env | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -Last 1
  if (-not $line) { return $null }
  $value = ($line -split '=',2)[1].Trim()
  if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
    $value = $value.Substring(1,$value.Length-2)
  }
  return $value
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
  .then(async r=>{const t=await r.text();console.log(String(r.status)+'|'+t);})
  .catch(e=>{console.error(e);process.exit(2);});
'@
  $out = & docker exec --env "ASSIS_PATH=$Path" --env "ASSIS_TOKEN=$Token" --env "ASSIS_BODY=$JsonBody" $n8n node -e $script 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao chamar n8n internamente:`n$($out -join "`n")" }
  return (($out | Where-Object { $_ }) -join "`n").Trim()
}

function Wait-N8nWebhook([string]$Path,[int]$TimeoutSeconds=120) {
  $probeBody = @{organization_id='00000000-0000-0000-0000-000000000001';conversation_id='00000000-0000-0000-0000-000000000002';idempotency_key='readiness-probe';to='5511999999999';text='readiness'} | ConvertTo-Json -Compress
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $attempt = 0
  do {
    $attempt++
    try {
      $probe = Invoke-N8nPost $Path 'invalid-readiness-token' $probeBody
      $status = ($probe -split '\|',2)[0].Trim()
      if ($status -and $status -ne '404') {
        Write-Host "PASS: rota outbound registrada após $attempt tentativa(s) (probe HTTP $status)."
        return
      }
    } catch {
      # n8n may still be starting; retry until the deadline.
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  $n8n = Get-ComposeContainer 'n8n'
  if ($n8n) {
    Write-Host '--- logs n8n (últimas 180 linhas) ---'
    & docker logs --tail 180 $n8n 2>&1 | Out-Host
  }
  throw "Webhook '$Path' não foi registrado em até ${TimeoutSeconds}s."
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }

Write-Host '=== Assis SmartFlow Evolution Outbound - Isolated Provider Gateway ==='
Write-Host '1/7 Validando configuração local do provider sem expor segredos ao n8n...'
$baseUrl = Read-EnvValue 'EVOLUTION_BASE_URL'
$apiKey = Read-EnvValue 'EVOLUTION_API_KEY'
$instance = Read-EnvValue 'EVOLUTION_INSTANCE'
$payloadStyle = Read-EnvValue 'EVOLUTION_SENDTEXT_PAYLOAD_STYLE'
if ([string]::IsNullOrWhiteSpace($payloadStyle)) { $payloadStyle = 'modern' }
if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw 'EVOLUTION_BASE_URL está vazio no .env.' }
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'EVOLUTION_API_KEY está vazio no .env. Configure localmente; não cole a chave no chat.' }
if ([string]::IsNullOrWhiteSpace($instance)) { throw 'EVOLUTION_INSTANCE está vazio no .env.' }
if ($payloadStyle -notin @('modern','legacy')) { throw 'EVOLUTION_SENDTEXT_PAYLOAD_STYLE deve ser modern ou legacy.' }
Write-Host "PASS: configuração Evolution outbound presente (payload_style=$payloadStyle); chave não exibida."

Write-Host '2/7 Construindo e iniciando somente o provider-gateway isolado...'
& docker compose @compose build provider-gateway | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir provider-gateway.' }
& docker compose @compose up -d --no-deps provider-gateway | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao iniciar provider-gateway.' }
$deadline = (Get-Date).AddSeconds(90)
do {
  $gateway = Get-ComposeContainer 'provider-gateway'
  if ($gateway) {
    $health = & docker exec $gateway python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=3).read().decode())" 2>$null
    if (($health -join '') -match '"evolution_configured"\s*:\s*true') { break }
  }
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ((Get-Date) -ge $deadline) {
  if ($gateway) { & docker logs --tail 120 $gateway 2>&1 | Out-Host }
  throw 'provider-gateway não ficou configurado e saudável em até 90s.'
}
$n8n = Get-ComposeContainer 'n8n'
$n8nSecretExposure = & docker exec $n8n sh -lc 'if [ -n "${EVOLUTION_API_KEY:-}" ] || [ -n "${EVOLUTION_INSTANCE:-}" ]; then echo PRESENT; else echo ABSENT; fi' 2>&1
if (($n8nSecretExposure -join '').Trim() -ne 'ABSENT') { throw 'Credenciais Evolution outbound foram expostas ao processo n8n.' }
Write-Host 'PASS: provider-gateway saudável; EVOLUTION_API_KEY/INSTANCE ausentes do processo n8n.'

Write-Host '3/7 Importando somente Policy Gateway e Outbound Text...'
& "$PSScriptRoot\import-workflows.ps1" -Force -Only $workflowPaths
if ($LASTEXITCODE -ne 0) { throw 'Falha ao importar workflows outbound.' }
& "$PSScriptRoot\bind-postgres-workflow-credentials.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao vincular credencial PostgreSQL.' }

Write-Host '4/7 Publicando somente os workflows outbound...'
foreach ($name in $workflowNames) {
  $escaped = $name.Replace("'","''")
  $id = Invoke-PgScalar @"
SELECT id FROM workflow_entity WHERE name='$escaped' ORDER BY "updatedAt" DESC LIMIT 1;
"@
  if ([string]::IsNullOrWhiteSpace($id)) { throw "Workflow '$name' não localizado no banco do n8n." }
  $publish = & docker exec -u node $n8n n8n publish:workflow --id=$id 2>&1
  if ($LASTEXITCODE -ne 0 -or (($publish -join "`n") -match '(?i)error|failed|not found')) {
    throw "Falha ao publicar '$name':`n$($publish -join "`n")"
  }
  Write-Host "  PASS: $name publicado."
}
& docker compose @compose restart n8n | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao reiniciar n8n para registrar rota outbound.' }
Write-Host 'Aguardando registro da rota outbound de produção no n8n...'
Wait-N8nWebhook '/webhook/assis/internal/message/send-text' 120

Write-Host '5/7 Validando contratos estáticos e isolamento de credenciais...'
& docker compose @compose --profile tools build qa | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir imagem QA.' }
& docker compose @compose --profile tools run --rm qa pytest -q tests/test_evolution_outbound.py tests/test_no_workflow_env_access.py -p no:cacheprovider | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha nos contratos estáticos do Evolution outbound.' }

Write-Host '6/7 Homologando rejeição de chamada interna não autenticada...'
$dummy = @{organization_id='00000000-0000-0000-0000-000000000001';conversation_id='00000000-0000-0000-0000-000000000002';idempotency_key='invalid-auth-smoke';to='5511999999999';text='invalid'} | ConvertTo-Json -Compress
$bad = Invoke-N8nPost '/webhook/assis/internal/message/send-text' 'invalid-outbound-token' $dummy
$badStatus = ($bad -split '\|',2)[0].Trim()
if ($badStatus -eq '200' -or $badStatus -eq '404') { throw "Outbound Text não demonstrou rejeição autenticada válida (HTTP $badStatus)." }
Write-Host "PASS: Outbound Text rejeitou token inválido (HTTP $badStatus)."

Write-Host '7/7 Homologação funcional do provider...'
$testNumber = Read-EnvValue 'EVOLUTION_TEST_NUMBER'
if ([string]::IsNullOrWhiteSpace($testNumber)) {
  Write-Host 'READY: EVOLUTION_TEST_NUMBER está vazio; nenhum WhatsApp real foi enviado automaticamente.'
  Write-Host 'A fronteira outbound, autenticação, idempotência e isolamento do provider estão implantados; falta somente o smoke real de entrega.'
  Write-Host ''
  Write-Host 'Para homologação E2E real, defina EVOLUTION_TEST_NUMBER no .env com um número autorizado e execute este script novamente.'
  exit 0
}

$internalToken = Read-EnvValue 'INTERNAL_AGENT_TOKEN'
if ([string]::IsNullOrWhiteSpace($internalToken) -or $internalToken.Length -lt 32) { throw 'INTERNAL_AGENT_TOKEN inválido para smoke outbound.' }
$marker = [guid]::NewGuid().ToString('N')
$slug = "evolution-outbound-$marker"
$idempotency = "evolution-outbound-$marker"
$setupSql = @"
WITH org AS (
  INSERT INTO organizations(slug,name,config) VALUES('$slug','Evolution Outbound Smoke','{"smoke_test":true}'::jsonb) RETURNING id
), contact AS (
  INSERT INTO contacts(organization_id,external_id,name,phone) SELECT id,'$testNumber','Evolution Outbound Smoke','$testNumber' FROM org RETURNING id,organization_id
), conv AS (
  INSERT INTO conversations(organization_id,contact_id,channel,external_id,last_message_at) SELECT organization_id,id,'whatsapp','$testNumber',now() FROM contact RETURNING id,organization_id
)
SELECT organization_id::text || '|' || id::text FROM conv;
"@
$ids = Invoke-PgScalar $setupSql
$parts = $ids -split '\|',2
if ($parts.Count -ne 2) { throw 'Falha ao criar contexto temporário para smoke outbound.' }
$orgId = $parts[0]
$conversationId = $parts[1]
try {
  $body = @{organization_id=$orgId;conversation_id=$conversationId;idempotency_key=$idempotency;to=$testNumber;text="Homologação Assis SmartFlow Evolution outbound $marker";channel='whatsapp'} | ConvertTo-Json -Compress
  $good = Invoke-N8nPost '/webhook/assis/internal/message/send-text' $internalToken $body
  $goodStatus = ($good -split '\|',2)[0].Trim()
  $goodBody = if ($good -match '\|') { ($good -split '\|',2)[1] } else { '' }
  if ($goodStatus -ne '200') {
    Write-Host '--- resposta outbound válida ---'
    Write-Host $goodBody
    Write-Host '--- logs provider-gateway ---'
    & docker logs --tail 140 $gateway 2>&1 | Out-Host
    throw "Outbound válido retornou HTTP $goodStatus."
  }
  Start-Sleep -Seconds 2
  $verifySql = @"
SELECT
  (SELECT count(*) FROM messages WHERE organization_id='$orgId'::uuid AND idempotency_key='$idempotency' AND direction='out')::text
  || '|' ||
  (SELECT count(*) FROM tool_idempotency WHERE organization_id='$orgId'::uuid AND operation='message.send_text' AND idempotency_key='$idempotency' AND status='completed')::text;
"@
  $verify = Invoke-PgScalar $verifySql
  if ($verify -ne '1|1') { throw "Persistência/idempotência outbound inesperada: $verify" }
  Write-Host 'PASS: mensagem real enviada pelo Evolution, persistida uma vez e idempotência marcada como completed.'
} finally {
  $cleanup = "DELETE FROM organizations WHERE id='$orgId'::uuid;"
  try { Invoke-PgScalar $cleanup | Out-Null } catch { Write-Warning 'Não foi possível remover automaticamente a organização temporária de smoke.' }
}

Write-Host ''
Write-Host 'PASS: Evolution outbound implantado e homologado E2E.'
Write-Host 'Fluxo: Policy Gateway -> Outbound Text autenticado/idempotente -> provider-gateway isolado -> Evolution API -> persistência PostgreSQL.'
Write-Host 'EVOLUTION_API_KEY não é exposta ao processo n8n nem armazenada em workflow JSON.'
