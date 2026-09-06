param(
  [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$credentialName = 'Assis PostgreSQL'
$credentialType = 'postgres'

$safeWorkflowNames = @(
  '01 Canonical Ingress',
  '02 Context Load',
  '03 Memory Write',
  '04 Handoff',
  '05 Kanban Upsert',
  '06 RAG Ingest',
  '07 RAG Search',
  '08 DLQ Capture',
  '11 CRM Upsert Contact',
  '12 CRM Update Stage',
  'Internal Tool Noop',
  'Internal Tool Policy Gateway',
  'Library Agent Runtime',
  'Internal reception.agent',
  'Internal calendar.agent',
  'Internal knowledge.agent',
  'Internal crm.agent',
  'Internal finance.agent',
  'Internal document.agent',
  'Internal voice.agent',
  'Internal handoff.agent',
  'Starter 07 Maya Multi-Agent Orchestrator'
)

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar o serviço ${Service}:`n$($out -join "`n")"
  }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

function Invoke-PostgresScalar([string]$Sql) {
  $result = & docker exec --env "ASSIS_SQL=$Sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar PostgreSQL:`n$($result -join "`n")"
  }
  return (($result | Where-Object { $_ }) -join '').Trim()
}

function Invoke-Postgres([string]$Sql) {
  $result = & docker exec --env "ASSIS_SQL=$Sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao executar PostgreSQL:`n$($result -join "`n")"
  }
  return ($result -join "`n")
}

$postgresContainer = Get-ComposeContainer 'postgres'
$n8nContainer = Get-ComposeContainer 'n8n'
if (-not $postgresContainer) { throw 'Container postgres não está em execução.' }
if (-not $n8nContainer) { throw 'Container n8n não está em execução.' }

$credentialCountSql = @"
SELECT count(*)
FROM credentials_entity
WHERE name = '$credentialName'
  AND type = '$credentialType';
"@
$credentialCount = [int](Invoke-PostgresScalar $credentialCountSql)
if ($credentialCount -eq 0) {
  throw "Credencial '$credentialName' do tipo '$credentialType' não encontrada. Crie/teste essa credencial no n8n antes de executar este script."
}
if ($credentialCount -gt 1) {
  throw "Há $credentialCount credenciais chamadas '$credentialName'. Mantenha apenas uma para permitir configuração automática segura."
}

$credentialIdSql = @"
SELECT id
FROM credentials_entity
WHERE name = '$credentialName'
  AND type = '$credentialType'
LIMIT 1;
"@
$credentialId = Invoke-PostgresScalar $credentialIdSql
if ([string]::IsNullOrWhiteSpace($credentialId)) { throw 'Não foi possível resolver o ID da credencial PostgreSQL.' }
Write-Host "Credencial PostgreSQL localizada: $credentialName ($credentialId)"

$projectIdSql = @'
SELECT p.id
FROM project p
JOIN project_relation pr ON pr."projectId" = p.id
WHERE pr.role = 'project:personalOwner'
ORDER BY p."createdAt"
LIMIT 1;
'@
$projectId = Invoke-PostgresScalar $projectIdSql
if ([string]::IsNullOrWhiteSpace($projectId)) {
  throw 'Projeto pessoal do owner não encontrado. Conclua o setup/login inicial do n8n.'
}
Write-Host "Projeto pessoal: $projectId"

$escapedCredentialId = $credentialId.Replace("'","''")
$escapedProjectId = $projectId.Replace("'","''")

$shareCredentialSql = @"
INSERT INTO shared_credentials ("credentialsId","projectId",role,"createdAt","updatedAt")
VALUES ('$escapedCredentialId','$escapedProjectId','credential:owner',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
ON CONFLICT ("credentialsId","projectId")
DO UPDATE SET role='credential:owner',"updatedAt"=CURRENT_TIMESTAMP;
"@
Invoke-Postgres $shareCredentialSql | Out-Host

$bindCredentialSql = @"
WITH target AS (
  SELECT id, name
  FROM credentials_entity
  WHERE id = '$escapedCredentialId'
), patched AS (
  SELECT we.id,
         jsonb_agg(
           CASE
             WHEN n.node ? 'credentials'
              AND (n.node->'credentials') ? 'postgres'
              AND (
                n.node->'credentials'->'postgres'->>'id' = 'ASSIS_POSTGRES'
                OR n.node->'credentials'->'postgres'->>'name' = '$credentialName'
              )
             THEN jsonb_set(
                    jsonb_set(
                      n.node,
                      '{credentials,postgres,id}',
                      to_jsonb(target.id::text),
                      true
                    ),
                    '{credentials,postgres,name}',
                    to_jsonb(target.name::text),
                    true
                  )
             ELSE n.node
           END
           ORDER BY n.ord
         ) AS nodes
  FROM workflow_entity we
  CROSS JOIN target
  CROSS JOIN LATERAL jsonb_array_elements(we.nodes::jsonb) WITH ORDINALITY AS n(node, ord)
  GROUP BY we.id
)
UPDATE workflow_entity we
SET nodes = patched.nodes::json,
    "updatedAt" = CURRENT_TIMESTAMP
FROM patched
WHERE we.id = patched.id
  AND we.nodes::jsonb IS DISTINCT FROM patched.nodes;
"@
Invoke-Postgres $bindCredentialSql | Out-Host

$unresolvedSql = @"
SELECT count(*)
FROM workflow_entity we
WHERE we.nodes::text LIKE '%ASSIS_POSTGRES%';
"@
$unresolved = [int](Invoke-PostgresScalar $unresolvedSql)
if ($unresolved -ne 0) {
  throw "Ainda existem $unresolved workflow(s) com referência simbólica ASSIS_POSTGRES. Publicação interrompida."
}
Write-Host 'PASS: referências ASSIS_POSTGRES resolvidas.'

$boundNodesSql = @"
SELECT count(*)
FROM workflow_entity we
CROSS JOIN LATERAL jsonb_array_elements(we.nodes::jsonb) AS n(node)
WHERE n.node->'credentials'->'postgres'->>'id' = '$escapedCredentialId';
"@
$boundNodes = [int](Invoke-PostgresScalar $boundNodesSql)
Write-Host "Nodes PostgreSQL vinculados à credencial real: $boundNodes"
if ($boundNodes -eq 0) { throw 'Nenhum node PostgreSQL foi vinculado. Publicação interrompida.' }

if (-not $SkipPublish) {
  foreach ($workflowName in $safeWorkflowNames) {
    $escapedName = $workflowName.Replace("'","''")
    $workflowIdSql = @"
SELECT id
FROM workflow_entity
WHERE name = '$escapedName'
ORDER BY "updatedAt" DESC
LIMIT 1;
"@
    $workflowId = Invoke-PostgresScalar $workflowIdSql
    if ([string]::IsNullOrWhiteSpace($workflowId)) {
      throw "Workflow seguro obrigatório não encontrado: $workflowName"
    }

    Write-Host "Publicando: $workflowName ($workflowId)"
    $publishOutput = & docker exec $n8nContainer n8n publish:workflow --id=$workflowId 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Falha ao publicar '$workflowName':`n$($publishOutput -join "`n")"
    }
  }

  Write-Host 'Reiniciando somente o n8n para aplicar publicação e webhooks...'
  & docker compose @compose restart n8n
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao reiniciar o n8n.' }
  Start-Sleep -Seconds 5
}

$publishedCountSql = @'
SELECT count(*)
FROM workflow_published_version wpv
JOIN workflow_entity we ON we.id = wpv."workflowId";
'@
$publishedCount = [int](Invoke-PostgresScalar $publishedCountSql)
Write-Host "Workflows publicados na instância: $publishedCount"
Write-Host 'PASS: núcleo Assis SmartFlow configurado com PostgreSQL e publicação controlada.'
Write-Host 'Adapters externos de Calendar, WhatsApp, Asaas e telefonia permaneceram fora desta publicação automática.'
