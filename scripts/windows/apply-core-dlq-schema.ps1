$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar o serviço ${Service}:`n$($out -join "`n")"
  }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

Write-Host '=== Assis SmartFlow Core DLQ Schema ==='
$postgres = Get-ComposeContainer 'postgres'
if (-not $postgres) { throw 'Container PostgreSQL não está em execução.' }

Write-Host 'Aplicando migração idempotente 006_core_dlq.sql...'
& docker exec $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/006_core_dlq.sql' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao aplicar 006_core_dlq.sql.' }

$verifySql = @'
SELECT
  to_regclass('public.dead_letter_events') IS NOT NULL AS table_exists,
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='dead_letter_events' AND indexname='idx_dlq_retry'
  ) AS retry_index_exists,
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='dead_letter_events' AND indexname='idx_dlq_event_key'
  ) AS event_key_index_exists;
'@
$result = & docker exec --env "ASSIS_SQL=$verifySql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F "|" -c "$ASSIS_SQL"' 2>&1
if ($LASTEXITCODE -ne 0) { throw "Falha ao verificar schema DLQ:`n$($result -join "`n")" }
$line = (($result | Where-Object { $_ }) -join '').Trim()
if ($line -ne 't|t|t') { throw "Schema DLQ incompleto após migração: $line" }

Write-Host 'PASS: dead_letter_events pertence ao Core e está disponível com índices de retry e event_key.'
Write-Host 'Nenhum volume ou dado existente foi removido.'
