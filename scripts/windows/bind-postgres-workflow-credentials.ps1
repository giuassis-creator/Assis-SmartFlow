$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$credentialName = 'Assis PostgreSQL'
$credentialType = 'postgres'

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}:`n$($out -join "`n")" }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Invoke-PgScalar([string]$Sql) {
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Invoke-Pg([string]$Sql) {
  $out = & docker exec --env "ASSIS_SQL=$Sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
}

$postgres = Get-ComposeContainer 'postgres'
if (-not $postgres) { throw 'Container PostgreSQL não encontrado.' }

$count = [int](Invoke-PgScalar "SELECT count(*) FROM credentials_entity WHERE name='$credentialName' AND type='$credentialType';")
if ($count -ne 1) { throw "Esperava exatamente uma credencial '$credentialName' do tipo '$credentialType'; encontrei $count." }
$credentialId = Invoke-PgScalar "SELECT id FROM credentials_entity WHERE name='$credentialName' AND type='$credentialType' LIMIT 1;"
$escapedId = $credentialId.Replace("'","''")

$patchEntity = @"
WITH target AS (
  SELECT id,name FROM credentials_entity WHERE id='$escapedId'
), patched AS (
  SELECT we.id,
         jsonb_agg(
           CASE WHEN n.node->'credentials'->'postgres'->>'id'='ASSIS_POSTGRES'
                  OR n.node->'credentials'->'postgres'->>'name'='$credentialName'
                THEN jsonb_set(
                       jsonb_set(n.node,'{credentials,postgres,id}',to_jsonb(target.id::text),true),
                       '{credentials,postgres,name}',to_jsonb(target.name::text),true)
                ELSE n.node END
           ORDER BY n.ord
         ) AS nodes
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
Invoke-Pg $patchEntity

# n8n 2.x publishes the workflow_history snapshot for the current versionId. Keep the
# credential binding consistent in both the editable workflow and its publishable snapshot.
$patchHistory = @"
WITH target AS (
  SELECT id,name FROM credentials_entity WHERE id='$escapedId'
), current_versions AS (
  SELECT id,"versionId" FROM workflow_entity
), patched AS (
  SELECT wh."workflowId",wh."versionId",
         jsonb_agg(
           CASE WHEN n.node->'credentials'->'postgres'->>'id'='ASSIS_POSTGRES'
                  OR n.node->'credentials'->'postgres'->>'name'='$credentialName'
                THEN jsonb_set(
                       jsonb_set(n.node,'{credentials,postgres,id}',to_jsonb(target.id::text),true),
                       '{credentials,postgres,name}',to_jsonb(target.name::text),true)
                ELSE n.node END
           ORDER BY n.ord
         ) AS nodes
  FROM workflow_history wh
  JOIN current_versions cv ON cv.id=wh."workflowId" AND cv."versionId"=wh."versionId"
  CROSS JOIN target
  CROSS JOIN LATERAL jsonb_array_elements(wh.nodes::jsonb) WITH ORDINALITY AS n(node,ord)
  GROUP BY wh."workflowId",wh."versionId"
)
UPDATE workflow_history wh
SET nodes=patched.nodes::json
FROM patched
WHERE wh."workflowId"=patched."workflowId"
  AND wh."versionId"=patched."versionId"
  AND wh.nodes::jsonb IS DISTINCT FROM patched.nodes;
"@
Invoke-Pg $patchHistory

$entityUnresolved = [int](Invoke-PgScalar "SELECT count(*) FROM workflow_entity WHERE nodes::text LIKE '%ASSIS_POSTGRES%';")
$historyUnresolved = [int](Invoke-PgScalar @'
SELECT count(*)
FROM workflow_history wh
JOIN workflow_entity we ON we.id=wh."workflowId" AND we."versionId"=wh."versionId"
WHERE wh.nodes::text LIKE '%ASSIS_POSTGRES%';
'@)
if ($entityUnresolved -ne 0 -or $historyUnresolved -ne 0) {
  throw "ASSIS_POSTGRES não resolvido: workflow_entity=$entityUnresolved, workflow_history atual=$historyUnresolved."
}
Write-Host "PASS: credencial PostgreSQL vinculada em workflow_entity e snapshots atuais: $credentialName ($credentialId)"
