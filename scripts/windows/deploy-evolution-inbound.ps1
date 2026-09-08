$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$workflowPath = 'starter/workflows/01-evolution-inbound.json'
$workflowName = 'Starter 01 Evolution Inbound'

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

if (-not (Test-Path .env)) { throw '.env não encontrado.' }

Write-Host '=== Assis SmartFlow Evolution Inbound ==='
Write-Host '1/5 Garantindo segredo forte do webhook Evolution...'
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

Write-Host '2/5 Importando somente o adapter Evolution...'
& "$PSScriptRoot\import-workflows.ps1" -Force -Only @($workflowPath)
if ($LASTEXITCODE -ne 0) { throw 'Falha ao importar workflow Evolution.' }

$postgres = Get-ComposeContainer 'postgres'
$n8n = Get-ComposeContainer 'n8n'
if (-not $postgres -or -not $n8n) { throw 'PostgreSQL ou n8n indisponível.' }

$escapedName = $workflowName.Replace("'","''")
$sql = "SELECT id FROM workflow_entity WHERE name='$escapedName' ORDER BY \"updatedAt\" DESC LIMIT 1;"
$workflowId = (& docker exec --env "ASSIS_SQL=$sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1 | Where-Object { $_ }) -join ''
$workflowId = $workflowId.Trim()
if ([string]::IsNullOrWhiteSpace($workflowId)) { throw 'Workflow Evolution importado não foi localizado no banco do n8n.' }

Write-Host '3/5 Publicando adapter e recarregando o n8n com o segredo atualizado...'
$publish = & docker exec -u node $n8n n8n publish:workflow --id=$workflowId 2>&1
if ($LASTEXITCODE -ne 0 -or (($publish -join "`n") -match '(?i)error|failed|not found')) {
  throw "Falha ao publicar workflow Evolution:`n$($publish -join "`n")"
}
& docker compose @compose up -d --no-deps --force-recreate n8n | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar somente o n8n com EVOLUTION_WEBHOOK_SECRET.' }

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

Write-Host '4/5 Validando contrato estático do adapter Evolution...'
& docker compose @compose --profile tools build qa | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir imagem QA.' }
& docker compose @compose --profile tools run --rm qa pytest -q tests/test_evolution_adapter_security.py | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha nos testes estáticos do adapter Evolution.' }

Write-Host '5/5 Homologando fronteira pública Evolution -> Canonical Ingress...'
$marker = [guid]::NewGuid().ToString('N')
$slug = "evolution-smoke-$marker"
$remote = "55119999$($marker.Substring(0,4))@s.whatsapp.net"
$msgId = "QA-$marker"
$insertOrg = "INSERT INTO organizations(slug,name,config) VALUES('$slug','Evolution Smoke','{\"smoke_test\":true}'::jsonb) RETURNING id;"
$orgId = (& docker exec --env "ASSIS_SQL=$insertOrg" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1 | Where-Object { $_ }) -join ''
$orgId = $orgId.Trim()
if ([string]::IsNullOrWhiteSpace($orgId)) { throw 'Não foi possível criar organização temporária para smoke Evolution.' }

try {
  $payload = @{ organization_slug=$slug; data=@{ key=@{ remoteJid=$remote; id=$msgId }; pushName='Evolution Smoke'; message=@{ conversation='Mensagem de homologação Evolution' } } } | ConvertTo-Json -Depth 8 -Compress
  $tmp = Join-Path $env:TEMP "assis-evolution-$marker.json"
  Set-Content -Path $tmp -Value $payload -Encoding utf8

  $badStatus = (& curl.exe -k -s -o NUL -w "%{http_code}" -X POST "https://assis.localhost/webhook/adapter/evolution/in" -H "Content-Type: application/json" -H "x-assis-secret: invalid-$marker" --data-binary "@$tmp").Trim()
  if ($badStatus -eq '200') { throw 'Adapter Evolution aceitou segredo inválido.' }
  Write-Host "PASS: segredo inválido rejeitado (HTTP $badStatus)."

  $goodStatus = (& curl.exe -k -s -o NUL -w "%{http_code}" -X POST "https://assis.localhost/webhook/adapter/evolution/in" -H "Content-Type: application/json" -H "x-assis-secret: $secret" --data-binary "@$tmp").Trim()
  if ($goodStatus -ne '200') { throw "Adapter Evolution válido retornou HTTP $goodStatus." }

  Start-Sleep -Seconds 2
  $verifySql = "SELECT count(*) FROM messages m JOIN organizations o ON o.id=m.organization_id WHERE o.slug='$slug' AND m.provider_message_id='$msgId' AND m.body='Mensagem de homologação Evolution';"
  $count = (& docker exec --env "ASSIS_SQL=$verifySql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1 | Where-Object { $_ }) -join ''
  if ([int]$count.Trim() -ne 1) { throw 'Mensagem Evolution não chegou ao Canonical Ingress/PostgreSQL.' }
  Write-Host 'PASS: Evolution autenticado atravessou o adapter e foi persistido pelo Canonical Ingress.'
} finally {
  Remove-Item -ErrorAction SilentlyContinue (Join-Path $env:TEMP "assis-evolution-$marker.json")
  $cleanupSql = "DELETE FROM organizations WHERE id='$orgId'::uuid;"
  & docker exec --env "ASSIS_SQL=$cleanupSql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' *> $null
}

Write-Host ''
Write-Host 'PASS: adapter Evolution Inbound endurecido e homologado.'
Write-Host 'Fluxo validado: webhook público autenticado -> normalização Evolution -> Canonical Ingress interno autenticado -> PostgreSQL.'
Write-Host 'Configure o mesmo EVOLUTION_WEBHOOK_SECRET no provedor Evolution usando o header x-assis-secret.'
