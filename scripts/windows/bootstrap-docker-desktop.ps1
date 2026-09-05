$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path "$PSScriptRoot\..\..")
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker CLI não encontrado. Abra o Docker Desktop e habilite integração WSL2." }
docker version | Out-Host
if (-not (Test-Path .env)) { Copy-Item .env.example .env; Write-Host "Criado .env. Ajuste senhas antes de produção." }
Write-Host "Validando projeto..."
python scripts/validate.py
python -m pytest -q
Write-Host "Validando Compose..."
docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml config | Out-Null
Write-Host "Subindo Core + IA local..."
docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml up -d --build
Write-Host "Status:"
docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml ps
Write-Host "n8n: https://assis.localhost (ou http://localhost:5678 para diagnóstico local)"
Write-Host "Ollama: http://localhost:11434 | Qdrant: http://localhost:6333 | STT: http://localhost:8000 | TTS: http://localhost:7860"
