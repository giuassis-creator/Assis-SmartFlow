param(
  [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$credentialName = 'Assis Google Calendar'
$credentialType = 'googleCalendarOAuth2Api'
$workflowNames = @(
  'Starter 04 Calendar Availability',
  'Starter 05 Calendar Book',
  'Starter 08 Calendar Reschedule',
  'Starter 09 Calendar Cancel'
)

function Get-ComposeContainer([string]$Service) {
  return (((& docker compose @compose ps -q $Service 2>&1 | Where-Object { $_ }) -join '').Trim())
}

function Invoke-PgScalar([string]$Sql) {
  $r = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($r -join "`n") }
  return (($r | Where-Object { $_ }) -join '').Trim()
}

function Invoke-Pg([string]$Sql) {
  $r = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($r -join "`n") }
}

$postgres = Get-ComposeContainer 'postgres'
$n8n = Get-ComposeContainer 'n8n'
if (-not $postgres -or -not $n8n) { throw 'PostgreSQL e n8n precisam estar em execução.' }

$count = [int](Invoke-PgScalar "SELECT count(*) FROM credentials_entity WHERE name='$credentialName' AND type='$credentialType';")
if ($count -eq 0) {
  throw "Credencial OAuth '$credentialName' ($credentialType) não encontrada. No n8n, crie uma credencial Google Calendar OAuth2 com exatamente esse nome, conclua o login Google e teste a conexão; depois execute este script novamente."
}
if ($count -gt 1) { throw "Há $count credenciais '$credentialName'. Mantenha apenas uma." }

$credentialId = Invoke-PgScalar "SELECT id FROM credentials_entity WHERE name='$credentialName' AND type='$credentialType' LIMIT 1;"
$escapedId = $credentialId.Replace("'","''")

$bind = @"
WITH target AS (
 SELECT id,name FROM credentials_entity WHERE id='$escapedId'
), patched AS (
 SELECT we.id,
        jsonb_agg(
          CASE WHEN (n.node->'credentials'->'googleCalendarOAuth2Api'->>'id'='ASSIS_GOOGLE_CALENDAR'
                  OR n.node->'credentials'->'googleCalendarOAuth2Api'->>'name'='$credentialName')
               THEN jsonb_set(jsonb_set(n.node,'{credentials,googleCalendarOAuth2Api,id}',to_jsonb(target.id::text),true),'{credentials,googleCalendarOAuth2Api,name}',to_jsonb(target.name::text),true)
               ELSE n.node END ORDER BY n.ord) AS nodes
 FROM workflow_entity we
 CROSS JOIN target
 CROSS JOIN LATERAL jsonb_array_elements(we.nodes::jsonb) WITH ORDINALITY AS n(node,ord)
 GROUP BY we.id
)
UPDATE workflow_entity we
SET nodes=patched.nodes::json,"updatedAt"=CURRENT_TIMESTAMP
FROM patched
WHERE we.id=patched.id AND we.nodes::jsonb IS DISTINCT FROM patched.nodes;
"@
Invoke-Pg $bind

$unresolved = [int](Invoke-PgScalar "SELECT count(*) FROM workflow_entity WHERE nodes::text LIKE '%ASSIS_GOOGLE_CALENDAR%';")
if ($unresolved -ne 0) { throw "Ainda existem $unresolved workflow(s) com ASSIS_GOOGLE_CALENDAR não resolvido." }
Write-Host "PASS: credencial Google Calendar vinculada: $credentialName ($credentialId)"

$ids = @()
foreach ($name in $workflowNames) {
  $escapedName = $name.Replace("'","''")
  $id = Invoke-PgScalar "SELECT id FROM workflow_entity WHERE name='$escapedName' ORDER BY \"updatedAt\" DESC LIMIT 1;"
  if (-not $id) { throw "Workflow não encontrado: $name. Rode import-workflows.ps1 -Force primeiro." }
  $ids += $id
  if (-not $SkipPublish) {
    Write-Host "Publicando adapter: $name ($id)"
    $out = & docker exec -u node $n8n n8n publish:workflow --id=$id 2>&1
    if ($LASTEXITCODE -ne 0 -or (($out -join "`n") -match '(?i)error|failed|not found')) { throw "Falha ao publicar ${name}:`n$($out -join "`n")" }
  }
}

if (-not $SkipPublish) {
  & docker compose @compose restart n8n | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao reiniciar n8n após publicar adapters Calendar.' }
}

Write-Host 'PASS: Google Calendar adapter configurado.'
Write-Host 'Disponibilidade é leitura; book/reschedule/cancel continuam exigindo confirmed=true e idempotency_key.'
