$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml','-f','core/docker-compose.waha-setup.yml')

function Read-EnvValue([string]$Name) {
  $line = Get-Content .env | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -Last 1
  if (-not $line) { return $null }
  $value = ($line -split '=',2)[1].Trim()
  if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
    $value = $value.Substring(1,$value.Length-2)
  }
  return $value
}

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}." }
  $id = (($out | Where-Object { $_ }) -join '').Trim()
  if (-not $id -or $id -notmatch '^[0-9a-f]{12,64}$') { throw "Container ${Service} não encontrado." }
  return $id
}

function Invoke-PgScalar([string]$Sql) {
  $postgres = Get-ComposeContainer 'postgres'
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Invoke-N8nPost([string]$Path,[string]$Token,[string]$JsonBody) {
  $n8n = Get-ComposeContainer 'n8n'
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

if (-not (Test-Path .env)) { throw '.env não encontrado.' }
Write-Host '=== Assis SmartFlow WAHA - Finalização da homologação runtime ==='

$session = Read-EnvValue 'WAHA_SESSION'
if ([string]::IsNullOrWhiteSpace($session)) { $session = 'default' }
$orgSlug = Read-EnvValue 'WAHA_ORGANIZATION_SLUG'
if ([string]::IsNullOrWhiteSpace($orgSlug)) { $orgSlug = 'default' }
if ($orgSlug -match '(?i)smoke') { throw "WAHA_ORGANIZATION_SLUG ainda aponta para tenant temporário: '$orgSlug'." }
$apiKey = Read-EnvValue 'WAHA_API_KEY'
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'WAHA_API_KEY não encontrado no .env.' }

$sessionUrl = 'http://127.0.0.1:3000/api/sessions/' + [uri]::EscapeDataString($session)
$state = Invoke-RestMethod -Uri $sessionUrl -Headers @{'X-Api-Key'=$apiKey;Accept='application/json'} -Method Get -TimeoutSec 10
if ($state.status -ne 'WORKING') {
  throw "Sessão WAHA '$session' ainda não está WORKING (status atual: $($state.status)). Conclua o pareamento antes da homologação runtime."
}
Write-Host "PASS: sessão WAHA '$session' está WORKING."

$sessionEsc = $session.Replace("'","''")
$orgEsc = $orgSlug.Replace("'","''")
$routeSql = @"
SELECT count(*)::text || '|' || min(o.slug)
FROM organization_whatsapp_providers p
JOIN organizations o ON o.id=p.organization_id
WHERE p.provider='waha'
  AND p.session_name='$sessionEsc'
  AND p.enabled=true;
"@
$route = Invoke-PgScalar $routeSql
$routeParts = $route -split '\|',2
if ($routeParts.Count -ne 2 -or $routeParts[0] -ne '1' -or $routeParts[1] -ne $orgSlug) {
  throw "Roteamento WAHA ambíguo/incorreto para sessão '$session': $route"
}
Write-Host "PASS: sessão '$session' possui exatamente uma rota ativa, organização '$orgSlug'."

$n8n = Get-ComposeContainer 'n8n'
$secretExposure = & docker exec $n8n sh -lc 'if [ -n "${WAHA_API_KEY:-}" ] || [ -n "${WAHA_WEBHOOK_SECRET:-}" ]; then echo PRESENT; else echo ABSENT; fi' 2>&1
if (($secretExposure -join '').Trim() -ne 'ABSENT') { throw 'Segredos WAHA estão expostos ao processo n8n.' }
Write-Host 'PASS: segredos WAHA continuam ausentes do processo n8n.'

$testNumber = Read-EnvValue 'WAHA_TEST_NUMBER'
if ([string]::IsNullOrWhiteSpace($testNumber)) {
  Write-Host 'PASS: runtime WAHA homologado até WORKING + isolamento + roteamento.'
  Write-Host 'INFO: WAHA_TEST_NUMBER está vazio; envio real foi corretamente omitido.'
  Write-Host 'NEXT: para homologar saída real, configure apenas um número autorizado em WAHA_TEST_NUMBER e execute este script novamente.'
  exit 0
}

if ($testNumber -notmatch '^\+?[0-9]{8,15}$') { throw 'WAHA_TEST_NUMBER deve conter somente DDI+DDD+número (8 a 15 dígitos, + opcional).' }
$internalToken = Read-EnvValue 'INTERNAL_AGENT_TOKEN'
if ([string]::IsNullOrWhiteSpace($internalToken) -or $internalToken.Length -lt 32) { throw 'INTERNAL_AGENT_TOKEN inválido para smoke E2E.' }

$marker = [guid]::NewGuid().ToString('N')
$idem = "waha-e2e-$marker"
$external = "waha-e2e-$marker"
$numEsc = $testNumber.Replace("'","''")
$externalEsc = $external.Replace("'","''")
$orgIdSql = "SELECT id::text FROM organizations WHERE slug='$orgEsc' LIMIT 1;"
$orgId = Invoke-PgScalar $orgIdSql
if ([string]::IsNullOrWhiteSpace($orgId)) { throw "Organização '$orgSlug' não encontrada." }

$contextSql = @"
WITH contact AS (
  INSERT INTO contacts(organization_id,external_id,name,phone,metadata)
  VALUES('$orgId'::uuid,'$externalEsc','WAHA E2E','$numEsc',jsonb_build_object('smoke_test',true))
  RETURNING id,organization_id
), conv AS (
  INSERT INTO conversations(organization_id,contact_id,channel,external_id,last_message_at,context)
  SELECT organization_id,id,'whatsapp','$externalEsc',now(),jsonb_build_object('smoke_test',true)
  FROM contact
  RETURNING id
)
SELECT id::text FROM conv;
"@
$conversationId = Invoke-PgScalar $contextSql
if ([string]::IsNullOrWhiteSpace($conversationId)) { throw 'Falha ao criar contexto temporário E2E.' }

try {
  $body = @{
    organization_id = $orgId
    conversation_id = $conversationId
    idempotency_key = $idem
    to = $testNumber
    text = "Homologação Assis SmartFlow WAHA $marker"
    channel = 'whatsapp'
  } | ConvertTo-Json -Compress

  $good = Invoke-N8nPost '/webhook/assis/internal/message/send-text' $internalToken $body
  $status = ($good -split '\|',2)[0].Trim()
  if ($status -ne '200') { throw "Outbound WAHA válido retornou HTTP $status.`n$good" }

  $countSql = "SELECT count(*) FROM messages WHERE organization_id='$orgId'::uuid AND idempotency_key='$idem';"
  $count = Invoke-PgScalar $countSql
  if ($count -ne '1') { throw "Persistência outbound inesperada: $count registro(s)." }

  $again = Invoke-N8nPost '/webhook/assis/internal/message/send-text' $internalToken $body
  $againStatus = ($again -split '\|',2)[0].Trim()
  if ($againStatus -eq '200') { throw 'Idempotência falhou: segunda chamada foi aceita como novo envio.' }

  Write-Host 'PASS: WAHA outbound real foi aceito pelo provider gateway.'
  Write-Host 'PASS: mensagem outbound foi persistida exatamente uma vez.'
  Write-Host 'PASS: idempotência impediu repetição do envio.'
  Write-Host 'PASS: homologação runtime WAHA concluída para saída real autorizada.'
} finally {
  $cleanupSql = @"
DELETE FROM contacts
WHERE organization_id='$orgId'::uuid
  AND external_id='$externalEsc';
"@
  Invoke-PgScalar $cleanupSql | Out-Null
}
