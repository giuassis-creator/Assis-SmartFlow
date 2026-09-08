param(
  [string]$CalendarId = 'primary',
  [switch]$SkipRuntimeSmoke
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$calendarWorkflowNames = @(
  'Starter 04 Calendar Availability',
  'Starter 05 Calendar Book',
  'Starter 08 Calendar Reschedule',
  'Starter 09 Calendar Cancel'
)

Write-Host 'Sincronizando workflows endurecidos no n8n...'
& "$PSScriptRoot\import-workflows.ps1" -Force
if ($LASTEXITCODE -ne 0) { throw 'Falha ao importar workflows.' }

# import-workflows.ps1 intentionally imports workflows inactive. Because the Calendar
# deployment force-imports the whole workflow catalog, Internal Auth Verify must be
# republished before any Calendar/Policy Gateway runtime call can authenticate.
Write-Host 'Restaurando autenticação interna após a importação forçada...'
& "$PSScriptRoot\configure-core-runtime.ps1" -SkipPublish
if ($LASTEXITCODE -ne 0) { throw 'Falha ao religar credenciais PostgreSQL do núcleo.' }
& "$PSScriptRoot\publish-internal-auth.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao republicar Internal Auth Verify.' }

Write-Host 'Aplicando migration, credenciais, publicação e Policy Gateway...'
& "$PSScriptRoot\configure-google-calendar.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar Google Calendar.' }

Write-Host 'Restaurando o n8n para a superfície normal HTTPS via Caddy...'
& docker compose @compose up -d --no-deps --force-recreate n8n | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao restaurar o n8n para a configuração normal.' }

$postgres = (((& docker compose @compose ps -q postgres 2>&1 | Where-Object { $_ }) -join '').Trim())
if (-not $postgres) { throw 'Container PostgreSQL não encontrado.' }

function Invoke-PgScalar([string]$Sql) {
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

# n8n 2.x can rebuild its in-memory production webhook router without persisting rows in
# webhook_entity for every published webhook. Treat activeVersionId as the publication
# source of truth and prove actual route registration with the runtime smoke below.
$calendarNamesSql = ($calendarWorkflowNames | ForEach-Object { "'$($_.Replace("'","''"))'" }) -join ','
$publishedSql = @"
SELECT count(*)
FROM workflow_entity
WHERE name IN ($calendarNamesSql)
  AND "activeVersionId" IS NOT NULL;
"@
$deadline = (Get-Date).AddSeconds(120)
$publishedCount = 0
do {
  try { $publishedCount = [int](Invoke-PgScalar $publishedSql) } catch { $publishedCount = 0 }
  if ($publishedCount -ge 4) { break }
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ($publishedCount -lt 4) { throw "Somente $publishedCount/4 workflows Calendar possuem activeVersionId após a publicação." }
Write-Host 'PASS: 4/4 workflows Calendar publicados (activeVersionId presente).'

$authPublished = [int](Invoke-PgScalar "SELECT count(*) FROM workflow_entity WHERE name='Internal Auth Verify' AND \"activeVersionId\" IS NOT NULL;")
if ($authPublished -ne 1) { throw 'Internal Auth Verify perdeu activeVersionId durante o deploy Calendar.' }
Write-Host 'PASS: Internal Auth Verify permanece publicado após o deploy Calendar.'

Write-Host 'Validando bloqueio público dos webhooks internos no Caddy...'
$publicStatus = (& curl.exe -k -s -o NUL -w "%{http_code}" -X POST "https://assis.localhost/webhook/assis/internal/calendar/availability" -H "Content-Type: application/json" -d '{}').Trim()
if ($publicStatus -ne '404') { throw "Webhook interno Calendar ficou acessível pelo proxy público; HTTP $publicStatus em vez de 404." }
Write-Host 'PASS: Caddy retorna 404 para Calendar interno.'

Write-Host 'Executando validação estática específica do Calendar...'
& docker compose @compose --profile tools build qa | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao construir imagem QA.' }
& docker compose @compose --profile tools run --rm qa pytest -q tests/test_calendar_adapters.py | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha na validação estática dos adapters Calendar.' }

if (-not $SkipRuntimeSmoke) {
  Write-Host "Executando homologação real contra Google Calendar '$CalendarId'."
  Write-Host 'O smoke cria um evento temporário identificado como [Assis SmartFlow QA], reagenda e cancela o mesmo evento.'
  & docker compose @compose --profile tools run --rm -e "CALENDAR_ID=$CalendarId" qa python scripts/smoke_calendar_runtime.py | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'Falha na homologação runtime do Google Calendar.' }
}

Write-Host 'PASS: implantação endurecida do Google Calendar concluída.'
Write-Host 'Superfície final: https://assis.localhost; porta 5678 não é necessária para operação normal.'
