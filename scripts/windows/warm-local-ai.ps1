$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

$model = 'qwen3:4b-instruct'
if (Test-Path '.env') {
  $line = Get-Content '.env' | Where-Object { $_ -match '^OLLAMA_CHAT_MODEL=' } | Select-Object -First 1
  if ($line) {
    $candidate = ($line -split '=',2)[1].Trim().Trim('"').Trim("'")
    if ($candidate) { $model = $candidate }
  }
}

$ollama = ((& docker compose @compose ps -q ollama 2>&1 | Where-Object { $_ }) -join '').Trim()
if (-not $ollama) { throw 'Container Ollama não está em execução.' }

Write-Host "Aquecendo modelo local $model antes da homologação..."
$warm = & docker exec $ollama ollama run $model 'Responda somente: OK' 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao aquecer modelo Ollama ${model}:`n$($warm -join "`n")"
}
Write-Host 'PASS: modelo local carregado e pronto para o smoke da Maya.'
