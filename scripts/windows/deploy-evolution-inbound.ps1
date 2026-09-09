$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$workflowPaths = @(
  'library/agents/11-internal-auth-verify.json',
  'library/workflows/01-canonical-ingress.json',
  'starter/workflows/01-evolution-inbound.json'
)
$workflowNames = @(
  'Internal Auth Verify',
  '01 Canonical Ingress',
  'Starter 01 Evolution Inbound'
)

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar $Service.`n$($out -join "`n")" }
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

function Set-EnvValue([string]$Name,[string]$Value) {
  $lines = @(Get-Content .env)
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  $found = $false
  $updated = foreach ($line in $lines) {
    if ($line -match $pattern) {
      if (-not $found) { "$Name=$Value"; $found = $true }
    } else { $line }
  }
  if (-not $found) { $updated += "$Name=$Value" }
  Set-Content -Path .env -Value $updated -Encoding utf8
}

function Get-Sha256Hex([string]$Value) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
  } finally {
    $sha.Dispose()
  }
  return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

function Invoke-PgScalar([string]$Sql) {
  $postgres = Get-ComposeContainer 'postgres'
  if (-not $postgres) { throw 'Container PostgreSQL não encontrado.' }
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }

Write-Host '=== Assis SmartFlow Evolution Inbound - Hashed Provider Auth ==='
Write-Host '1/6 Garantindo segredo forte do webhook Evolution e registrando somente o hash...'
$secret = Read-EnvValue 'EVOLUTION_WEBHOOK_SECRET'
if ([string]::IsNullOrWhiteSpace($secret) -or $secret -eq 'CHANGE_ME_LONG_RANDOM_EVOLUTION_SECRET' -or $secret.Length -lt 32) {
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  $secret = -join ($bytes | ForEach-Object { $_.ToString('x2') })
  Set-EnvValue 'EVOLUTION_WEBHOOK_SECRET' $secret
  Write-Host 'PASS: segredo Evolution forte gerado e salvo somente no .env.'
} else {
  Write-Host 'PASS: segredo Evolution existente preservado.'
}

$postgres = Get-ComposeContainer 'postgres'
$n8n = Get-ComposeContainer 'n8n'
if (-not $postgres -or -not $n8n) { throw 'PostgreSQL ou n8n indisponível.' }
$secretHash = Get-Sha256Hex $secret
$hashSql = @"
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS internal_auth_secrets (
  name text PRIMARY KEY,
  token_sha256 text NOT NULL CHECK (token_sha256 ~ '^[0-9a-f]{64}$'),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO internal_auth_secrets(name,token_sha256,updated_at)
VALUES ('evolution-webhook','$secretHash',CURRENT_TIMESTAMP)
ON CONFLICT(name)
DO UPDATE SET token_sha256=EXCLUDED.token_sha256,updated_at=CURRENT_TIMESTAMP;
"@
& docker exec --env "ASSIS_SQL=$hashSql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao registrar hash do segredo Evolution.' }
Write-Host 'PASS: PostgreSQL contém somente o SHA-256 do segredo Evolution.'

Write-Host '2/6 Importando somente verifier, Canonical Ingress e adapter Evolution...'
& "$PSScriptRoot\import-workflows.ps1" -Force -Only $workflowPaths
if ($LASTEXITCODE -ne 0) { throw 'Falha ao importar workflows da fronteira Evolution.' }
& "$PSScriptRoot\bind-postgres-workflow-credentials.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao vincular credencial PostgreSQL.' }

Write-Host '3/6 Publicando somente os workflows desta fronteira...'
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

Write-Host '4/6 Recriando somente o n8n sem expor EVOLUTION_WEBHOOK_SECRET ao processo...'
& docker compose @compose up -d --no-deps --force-recreate n8n | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar somente o n8n.' }
$deadline = (Get-Date).AddSeconds(120)
do {
  $n8n = Get-ComposeContainer 'n8n'
  if ($n8n) {
    $ready = & docker exec $n8n sh -lc 'wget -q -O- http://127.0.0.1:5678/healthz >/dev/null 2>&1; echo $?' 2>$null
    if (($ready -join '').Trim() -eq '0') { break }
  }
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ((Get-Date) -ge $deadline) { throw 'n8n não ficou pronto em até 120s.' }
Start-Sleep -Seconds 3

$envCheck = & docker exec $n8n sh -lc 'if [ -n "${EVOLUTION_WEBHOOK_SECRET:-}" ]; then echo PRESENT; else echo ABSENT; fi' 2>&1
if (($envCheck -join '').Trim() -ne 'ABSENT') { throw 'EVOLUTION_WEBHOOK_SECRET ainda está exposto no ambiente do n8n.' }
Write-Host 'PASS: EVOLUTION_WEBHOOK_SECRET ausente do ambiente do processo n8n.'

Write-Host '5/6 Validando contratos estáticos da autenticação escopada...'
& docker compose @compose --profile tools build qa | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir imagem QA.' }
& docker compose @compose --profile tools run --rm qa pytest -q tests/test_evolution_adapter_security.py tests/test_canonical_ingress_security.py -p no:cacheprovider | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha nos testes estáticos da fronteira Evolution/Canonical.' }

Write-Host '6/6 Homologando webhook público -> hash PostgreSQL -> Canonical Ingress...'
$marker = [guid]::NewGuid().ToString('N')
$slug = "evolution-smoke-$marker"
$remote = "55119999$($marker.Substring(0,4))@s.whatsapp.net"
$msgId = "QA-$marker"
$insertOrg = @"
INSERT INTO organizations(slug,name,config)
VALUES('$slug','Evolution Smoke','{"smoke_test":true}'::jsonb)
RETURNING id;
"@
$orgId = Invoke-PgScalar $insertOrg
if ([string]::IsNullOrWhiteSpace($orgId)) { throw 'Não foi possível criar organização temporária para smoke Evolution.' }

try {
  $payload = @{ organization_slug=$slug; data=@{ key=@{ remoteJid=$remote; id=$msgId }; pushName='Evolution Smoke'; message=@{ conversation='Mensagem de homologação Evolution' } } } | ConvertTo-Json -Depth 8 -Compress
  $tmp = Join-Path $env:TEMP "assis-evolution-$marker.json"
  $badOut = Join-Path $env:TEMP "assis-evolution-bad-$marker.txt"
  $goodOut = Join-Path $env:TEMP "assis-evolution-good-$marker.txt"
  Set-Content -Path $tmp -Value $payload -Encoding utf8

  $badStatus = (& curl.exe -k -sS -o $badOut -w "%{http_code}" -X POST "https://assis.localhost/webhook/adapter/evolution/in" -H "Content-Type: application/json" -H "x-assis-secret: invalid-$marker" --data-binary "@$tmp").Trim()
  if ($badStatus -eq '200') { throw 'Adapter Evolution aceitou segredo inválido.' }
  Write-Host "PASS: segredo inválido rejeitado (HTTP $badStatus)."

  $goodStatus = (& curl.exe -k -sS -o $goodOut -w "%{http_code}" -X POST "https://assis.localhost/webhook/adapter/evolution/in" -H "Content-Type: application/json" -H "x-assis-secret: $secret" --data-binary "@$tmp").Trim()
  if ($goodStatus -ne '200') {
    $goodBody = if (Test-Path $goodOut) { (Get-Content $goodOut -Raw).Trim() } else { '' }
    Write-Host '--- corpo da resposta Evolution válida ---'
    if ($goodBody) { Write-Host $goodBody } else { Write-Host '(vazio)' }
    Write-Host '--- últimas 140 linhas do log n8n ---'
    & docker logs --tail 140 $n8n 2>&1 | Out-Host
    throw "Adapter Evolution válido retornou HTTP $goodStatus. Diagnóstico acima."
  }

  Start-Sleep -Seconds 2
  $verifySql = @"
SELECT count(*)
FROM messages m
JOIN organizations o ON o.id=m.organization_id
WHERE o.slug='$slug'
  AND m.provider_message_id='$msgId'
  AND m.body='Mensagem de homologação Evolution';
"@
  $count = Invoke-PgScalar $verifySql
  if ([int]$count -ne 1) { throw 'Mensagem Evolution não chegou ao Canonical Ingress/PostgreSQL.' }
  Write-Host 'PASS: Evolution autenticado por hash atravessou o adapter e foi persistido pelo Canonical Ingress.'
} finally {
  Remove-Item -ErrorAction SilentlyContinue (Join-Path $env:TEMP "assis-evolution-$marker.json")
  Remove-Item -ErrorAction SilentlyContinue (Join-Path $env:TEMP "assis-evolution-bad-$marker.txt")
  Remove-Item -ErrorAction SilentlyContinue (Join-Path $env:TEMP "assis-evolution-good-$marker.txt")
  if ($orgId) {
    $cleanupSql = "DELETE FROM organizations WHERE id='$orgId'::uuid;"
    & docker exec --env "ASSIS_SQL=$cleanupSql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' *> $null
  }
}

Write-Host ''
Write-Host 'PASS: adapter Evolution Inbound sem acesso a $env implantado e homologado.'
Write-Host 'Fluxo: segredo bruto somente no .env do host/provedor -> hash PostgreSQL -> verifier escopado -> adapter -> Canonical Ingress -> PostgreSQL.'
Write-Host 'O segredo Evolution não é mais injetado no ambiente do processo n8n.'
