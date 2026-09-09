$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

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
  for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $pattern) {
      $lines[$i] = "$Name=$Value"
      $found = $true
    }
  }
  if (-not $found) { $lines += "$Name=$Value" }
  Set-Content .env -Value $lines -Encoding utf8
}

function Get-ComposeContainer([string]$Service) {
  $compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
  $out = & docker compose @compose ps -q $Service 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}." }
  $id = (($out | Where-Object { $_ }) -join '').Trim()
  if (-not $id -or $id -notmatch '^[0-9a-f]{12,64}$') { throw "Container ${Service} não encontrado." }
  return $id
}

if (-not (Test-Path .env)) { throw '.env não encontrado.' }

$session = Read-EnvValue 'WAHA_SESSION'
if ([string]::IsNullOrWhiteSpace($session)) { $session = 'default'; Set-EnvValue 'WAHA_SESSION' $session }
$orgName = Read-EnvValue 'ORG_NAME'
if ([string]::IsNullOrWhiteSpace($orgName)) { $orgName = 'Minha Empresa' }

# The initial failed deployment could persist a temporary evolution-smoke-* slug
# in WAHA_ORGANIZATION_SLUG. A real WhatsApp session must never be paired to a
# smoke-test tenant. Re-home the configured WAHA session to the canonical default
# organization before allowing pairing.
$currentSlug = Read-EnvValue 'WAHA_ORGANIZATION_SLUG'
$mustRepair = [string]::IsNullOrWhiteSpace($currentSlug) -or $currentSlug -match '(?i)(^|[-_])smoke([-_]|$)' -or $currentSlug -match '(?i)^evolution-smoke-'
if ($mustRepair) {
  Set-EnvValue 'WAHA_ORGANIZATION_SLUG' 'default'
  Write-Host "REPAIR: WAHA_ORGANIZATION_SLUG alterado de tenant temporário para 'default'."
} elseif ($currentSlug -ne 'default') {
  Write-Host "INFO: WAHA_ORGANIZATION_SLUG='$currentSlug' foi definido explicitamente e será preservado."
}

$postgres = Get-ComposeContainer 'postgres'
$sessionEsc = $session.Replace("'","''")
$nameEsc = $orgName.Replace("'","''")
$sql = @"
BEGIN;
INSERT INTO organizations(slug,name,config)
VALUES('default','$nameEsc','{}'::jsonb)
ON CONFLICT(slug) DO NOTHING;

DELETE FROM organization_whatsapp_providers p
USING organizations o
WHERE p.organization_id=o.id
  AND p.provider='waha'
  AND p.session_name='$sessionEsc'
  AND o.slug<>'default';

INSERT INTO organization_whatsapp_providers(organization_id,provider,session_name,priority,enabled,config,updated_at)
SELECT id,'waha','$sessionEsc',1,true,'{}'::jsonb,now()
FROM organizations
WHERE slug='default'
ON CONFLICT(organization_id,provider,session_name)
DO UPDATE SET priority=1,enabled=true,updated_at=now();
COMMIT;

SELECT o.slug||'|'||p.provider||'|'||p.session_name||'|'||p.enabled::text
FROM organization_whatsapp_providers p
JOIN organizations o ON o.id=p.organization_id
WHERE p.provider='waha' AND p.session_name='$sessionEsc'
ORDER BY p.priority,o.slug;
"@

$out = & docker exec --env "ASSIS_SQL=$sql" $postgres sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$ASSIS_SQL"' 2>&1
if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
$route = (($out | Where-Object { $_ -match '^default\|waha\|' }) -join '').Trim()
if (-not $route) { throw 'Falha ao validar o vínculo WAHA da organização default.' }
Write-Host "PASS: sessão WAHA '$session' pertence somente à organização 'default'."
Write-Host 'PASS: tenant temporário não será usado no pareamento WhatsApp.'

& "$PSScriptRoot\deploy-waha-provider.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
