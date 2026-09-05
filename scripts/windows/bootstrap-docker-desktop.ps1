param(
  [switch]$ForceEnv,
  [switch]$ForceImport,
  [switch]$SkipWorkflowImport,
  [switch]$SkipSmoke
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker CLI não encontrado. Abra o Docker Desktop e habilite integração WSL2.' }
docker version | Out-Host
docker compose version | Out-Host
& "$PSScriptRoot\new-assis-env.ps1" -Force:$ForceEnv
Write-Host 'Validando Compose do Docker Desktop...'
docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml config | Out-Null
Write-Host 'Executando QA em container (não requer Python instalado no Windows)...'
docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml run --rm qa
Write-Host 'Subindo Core + IA local...'
docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml up -d --build
Write-Host 'Status inicial:'
docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml ps
& "$PSScriptRoot\init-qdrant.ps1"
if (-not $SkipWorkflowImport) { & "$PSScriptRoot\import-workflows.ps1" -Force:$ForceImport }
if (-not $SkipSmoke) { & "$PSScriptRoot\smoke-local-ai.ps1" }
Write-Host ''
Write-Host 'Assis SmartFlow implantado localmente.'
Write-Host 'n8n: https://assis.localhost (ou http://localhost:5678 para diagnóstico)'
Write-Host 'Ollama: http://localhost:11434 | Qdrant: http://localhost:6333 | STT: http://localhost:8000 | TTS: http://localhost:7860'
Write-Host 'Abra o n8n, conclua o usuário proprietário, configure credenciais de canais/calendário e ative somente os workflows desejados.'
