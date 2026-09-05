$ErrorActionPreference='Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

docker compose --env-file .env -f core/docker-compose.yml -f core/docker-compose.desktop.yml run --rm qa python scripts/init_qdrant.py
