param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$markerDir = Join-Path $root '.local'
$marker = Join-Path $markerDir 'workflow-import-v1.done'
if ((Test-Path $marker) -and -not $Force) {
  Write-Host 'Workflows já importados neste clone. Use -Force apenas se você souber que deseja reimportá-los.'
  exit 0
}
New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')
$paths = @(
  '/opt/assis/library/agents',
  '/opt/assis/library/workflows',
  '/opt/assis/starter/workflows',
  '/opt/assis/professional/workflows',
  '/opt/assis/enterprise/workflows'
)
foreach ($path in $paths) {
  Write-Host "Importando $path ..."
  $script = "set -e; for f in $path/*.json; do [ -f \"`$f\" ] || continue; case \"`$f\" in */manifest.json|*/catalog.json) continue ;; esac; echo \"  -> `$f\"; n8n import:workflow --input=\"`$f\"; done"
  & docker compose @compose exec -T n8n sh -lc $script
  if ($LASTEXITCODE -ne 0) { throw "Falha ao importar workflows de $path" }
}
Set-Content -Path $marker -Value (Get-Date).ToString('o') -Encoding ascii
Write-Host 'Workflows importados. Eles permanecem desativados por segurança até as credenciais/provedores serem configurados.'
