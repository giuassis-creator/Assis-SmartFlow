$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}:`n$($out -join "`n")" }
  return (($out | Where-Object { $_ }) -join '').Trim()
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

function Invoke-PgLines([string]$Sql) {
  $postgres = Get-ComposeContainer 'postgres'
  if (-not $postgres) { throw 'Container PostgreSQL não encontrado.' }
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return @($out | Where-Object { $_ })
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }

Write-Host '=== Assis SmartFlow - n8n Environment Hardening ==='
Write-Host '1/6 Auditando arquivos de workflow no repositório...'
$workflowRoots = @('library','starter','professional','enterprise')
$repoOffenders = @()
foreach ($dir in $workflowRoots) {
  if (-not (Test-Path $dir)) { continue }
  $repoOffenders += Get-ChildItem $dir -Recurse -File -Filter '*.json' | Where-Object {
    Select-String -Path $_.FullName -SimpleMatch '$env.' -Quiet
  } | ForEach-Object { $_.FullName.Substring($root.Path.Length + 1) }
}
if ($repoOffenders.Count -gt 0) {
  throw "Ainda existem workflows no repositório com acesso a `$env:`n$($repoOffenders -join "`n")"
}
Write-Host 'PASS: nenhum workflow versionado usa $env.'

Write-Host '2/6 Auditando workflows ATIVOS atualmente no banco do n8n...'
$activeEnvSql = @'
SELECT name || '|' || id
FROM workflow_entity
WHERE "activeVersionId" IS NOT NULL
  AND nodes::text LIKE '%$env.%'
ORDER BY name;
'@
$activeOffenders = @(Invoke-PgLines $activeEnvSql)
if ($activeOffenders.Count -gt 0) {
  throw "Há workflows ativos no n8n que ainda dependem de `$env. Hardening interrompido antes de alterar .env:`n$($activeOffenders -join "`n")"
}
Write-Host 'PASS: nenhum workflow ativo depende de $env.'

Write-Host '3/6 Ativando N8N_BLOCK_ENV_ACCESS_IN_NODE=true no .env local...'
Set-EnvValue 'N8N_BLOCK_ENV_ACCESS_IN_NODE' 'true'
Write-Host 'PASS: bloqueio persistido no .env.'

Write-Host '4/6 Recriando somente o n8n e verificando isolamento do processo...'
& docker compose @compose up -d --no-deps --force-recreate n8n | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar n8n com bloqueio de ambiente.' }
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

$block = (& docker exec $n8n sh -lc 'printf "%s" "${N8N_BLOCK_ENV_ACCESS_IN_NODE:-}"' 2>&1 | Out-String).Trim()
if ($block -ne 'true') { throw "N8N_BLOCK_ENV_ACCESS_IN_NODE não está true no container: '$block'" }
$internalTokenExposure = (& docker exec $n8n sh -lc 'if [ -n "${INTERNAL_AGENT_TOKEN:-}" ]; then echo PRESENT; else echo ABSENT; fi' 2>&1 | Out-String).Trim()
if ($internalTokenExposure -ne 'ABSENT') { throw 'INTERNAL_AGENT_TOKEN ainda está exposto no ambiente do processo n8n.' }
$evolutionExposure = (& docker exec $n8n sh -lc 'if [ -n "${EVOLUTION_WEBHOOK_SECRET:-}" ]; then echo PRESENT; else echo ABSENT; fi' 2>&1 | Out-String).Trim()
if ($evolutionExposure -ne 'ABSENT') { throw 'EVOLUTION_WEBHOOK_SECRET ainda está exposto no ambiente do processo n8n.' }
Write-Host 'PASS: bloqueio ativo; tokens internos/Evolution não estão no ambiente do n8n.'

Write-Host '5/6 Validando contrato estático de ausência de $env...'
& docker compose @compose --profile tools build qa | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir imagem QA.' }
& docker compose @compose --profile tools run --rm qa pytest -q -p no:cacheprovider tests/test_no_workflow_env_access.py | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Contrato de bloqueio de acesso a ambiente falhou.' }

Write-Host '6/6 Homologando Core e Evolution com o bloqueio realmente ativo...'
# Child PowerShell scripts already throw on failure. Do not inspect $LASTEXITCODE
# after they return because it may contain the exit code of the last native
# command executed inside the child script even when the child completed with PASS.
& "$PSScriptRoot\deploy-core-runtime.ps1"
Write-Host 'PASS: Core Runtime concluiu sem exceção com bloqueio de ambiente.'
& "$PSScriptRoot\deploy-evolution-inbound.ps1"
Write-Host 'PASS: Evolution Inbound concluiu sem exceção com bloqueio de ambiente.'

$n8n = Get-ComposeContainer 'n8n'
$blockFinal = (& docker exec $n8n sh -lc 'printf "%s" "${N8N_BLOCK_ENV_ACCESS_IN_NODE:-}"' 2>&1 | Out-String).Trim()
if ($blockFinal -ne 'true') { throw 'O deploy subsequente reverteu o bloqueio de acesso ao ambiente.' }

Write-Host ''
Write-Host 'PASS: N8N_BLOCK_ENV_ACCESS_IN_NODE=true implantado e homologado.'
Write-Host 'Segredos internos/provider não dependem mais de $env em workflows ativos; Core e Evolution passaram com o bloqueio habilitado.'
Write-Host 'Volumes e dados persistentes não foram removidos nem recriados.'
