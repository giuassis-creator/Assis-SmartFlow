param(
  [switch]$SkipPublish,
  [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

Write-Host '=== Assis SmartFlow Core Runtime ==='
Write-Host '1/3 Validando serviços Docker...'
& docker compose @compose ps | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Falha ao consultar Docker Compose.' }

Write-Host '2/3 Vinculando credenciais e publicando núcleo seguro...'
& "$PSScriptRoot\configure-core-runtime.ps1" -SkipPublish:$SkipPublish
if ($LASTEXITCODE -ne 0) { throw 'Falha na configuração do Core Runtime.' }

if (-not $SkipSmoke) {
  Write-Host '3/3 Executando homologação integrada do núcleo...'
  & docker compose @compose run --rm qa python scripts/smoke_core_runtime.py
  if ($LASTEXITCODE -ne 0) { throw 'Homologação do Core Runtime falhou.' }
} else {
  Write-Host '3/3 Smoke test ignorado por parâmetro.'
}

Write-Host ''
Write-Host 'PASS: implantação do Core Runtime concluída.'
Write-Host 'Núcleo validado: PostgreSQL + RAG + Policy Gateway + Agent Runtime + Maya/Ollama.'
Write-Host 'Adapters externos continuam desativados até configuração das credenciais/provider adapters.'
