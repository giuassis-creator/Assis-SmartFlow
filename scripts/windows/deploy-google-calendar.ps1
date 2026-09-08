param(
  [string]$CalendarId = 'primary',
  [switch]$SkipRuntimeSmoke
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

Write-Host 'Sincronizando workflows endurecidos no n8n...'
& "$PSScriptRoot\import-workflows.ps1" -Force
if ($LASTEXITCODE -ne 0) { throw 'Falha ao importar workflows.' }

Write-Host 'Aplicando migration, credenciais, publicação e Policy Gateway...'
& "$PSScriptRoot\configure-google-calendar.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar Google Calendar.' }

Write-Host 'Restaurando o n8n para a superfície normal HTTPS via Caddy...'
& docker compose @compose up -d --no-deps --force-recreate n8n | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao restaurar o n8n para a configuração normal.' }

Write-Host 'Aguardando webhooks internos do Calendar (até 120s)...'
$postgres = (((& docker compose @compose ps -q postgres 2>&1 | Where-Object { $_ }) -join '').Trim())
if (-not $postgres) { throw 'Container PostgreSQL não encontrado.' }
$calendarWebhookSql = @'
SELECT count(*)
FROM webhook_entity
WHERE path IN (
  'assis/internal/calendar/availability',
  'assis/internal/calendar/book',
  'assis/internal/calendar/reschedule',
  'assis/internal/calendar/cancel'
);
'@
$deadline = (Get-Date).AddSeconds(120)
$webhookCount = 0
do {
  $out = & docker exec --env "ASSIS_SQL=$calendarWebhookSql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -eq 0) {
    $raw = (($out | Where-Object { $_ }) -join '').Trim()
    if ($raw -match '^\d+$') { $webhookCount = [int]$raw }
  }
  if ($webhookCount -ge 4) { break }
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ($webhookCount -lt 4) { throw "Somente $webhookCount/4 webhooks internos do Calendar foram registrados." }
Write-Host 'PASS: 4/4 webhooks internos do Calendar registrados.'

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
