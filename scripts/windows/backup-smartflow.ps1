param(
  [ValidateRange(1, 3650)]
  [int]$RetentionDays = 30,

  [string]$MirrorPath
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$backupDir = Join-Path $root '.local\backups'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$compose = @('--env-file', '.env', '-f', 'core/docker-compose.yml', '-f', 'core/docker-compose.desktop.yml')
$postgresContainer = ((& docker compose @compose ps -q postgres 2>$null) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or -not $postgresContainer) {
  throw 'Container PostgreSQL não está em execução.'
}

$pgUser = ((& docker exec $postgresContainer printenv POSTGRES_USER 2>$null) -join '').Trim()
$pgDatabase = ((& docker exec $postgresContainer printenv POSTGRES_DB 2>$null) -join '').Trim()
if (-not $pgUser -or -not $pgDatabase) {
  throw 'Configuração PostgreSQL incompleta no container.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$fileName = "smartflow-$stamp.dump"
$containerFile = "/tmp/$fileName"
$partialFile = Join-Path $backupDir "$fileName.partial"
$finalFile = Join-Path $backupDir $fileName
$completed = $false

try {
  & docker exec $postgresContainer pg_dump `
    --username $pgUser `
    --dbname $pgDatabase `
    --format custom `
    --file $containerFile
  if ($LASTEXITCODE -ne 0) { throw 'pg_dump falhou.' }

  & docker cp "$($postgresContainer):$containerFile" $partialFile
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao copiar backup do container.' }

  $backupInfo = Get-Item -LiteralPath $partialFile
  if ($backupInfo.Length -lt 1024) {
    throw "Backup inválido ou vazio: $($backupInfo.Length) bytes."
  }

  Move-Item -LiteralPath $partialFile -Destination $finalFile
  $completed = $true
} finally {
  if ($postgresContainer -and $containerFile) {
    & docker exec $postgresContainer rm -f $containerFile 2>$null | Out-Null
  }
  if (-not $completed -and (Test-Path -LiteralPath $partialFile)) {
    Remove-Item -LiteralPath $partialFile -Force
  }
}

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
$expired = @(
  Get-ChildItem -LiteralPath $backupDir -Filter 'smartflow-*.dump' -File |
    Where-Object { $_.LastWriteTimeUtc -lt $cutoff -and $_.FullName -ne $finalFile }
)
foreach ($file in $expired) {
  Remove-Item -LiteralPath $file.FullName -Force
}

$mirrorFinal = $null
$mirrorExpired = @()
if ($MirrorPath) {
  $localFullPath = [System.IO.Path]::GetFullPath($backupDir).TrimEnd('\')
  $mirrorFullPath = [System.IO.Path]::GetFullPath($MirrorPath).TrimEnd('\')
  if ($mirrorFullPath -eq $localFullPath) {
    throw 'O espelho deve ser diferente da pasta local de backups.'
  }

  New-Item -ItemType Directory -Force -Path $mirrorFullPath | Out-Null
  $mirrorPartial = Join-Path $mirrorFullPath "$fileName.partial"
  $mirrorFinal = Join-Path $mirrorFullPath $fileName
  try {
    Copy-Item -LiteralPath $finalFile -Destination $mirrorPartial -Force
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $finalFile).Hash
    $mirrorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $mirrorPartial).Hash
    if ($sourceHash -ne $mirrorHash) {
      throw 'A cópia espelhada não passou na verificação SHA-256.'
    }
    Move-Item -LiteralPath $mirrorPartial -Destination $mirrorFinal -Force
  } finally {
    if (Test-Path -LiteralPath $mirrorPartial) {
      Remove-Item -LiteralPath $mirrorPartial -Force
    }
  }

  $mirrorExpired = @(
    Get-ChildItem -LiteralPath $mirrorFullPath -Filter 'smartflow-*.dump' -File |
      Where-Object { $_.LastWriteTimeUtc -lt $cutoff -and $_.FullName -ne $mirrorFinal }
  )
  foreach ($file in $mirrorExpired) {
    Remove-Item -LiteralPath $file.FullName -Force
  }
}

$result = [ordered]@{
  completed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  ok = $true
  file = $fileName
  bytes = (Get-Item -LiteralPath $finalFile).Length
  retention_days = $RetentionDays
  removed_expired = $expired.Count
  mirror_path = $mirrorFinal
  mirror_bytes = if ($mirrorFinal) { (Get-Item -LiteralPath $mirrorFinal).Length } else { $null }
  mirror_removed_expired = $mirrorExpired.Count
}
($result | ConvertTo-Json -Compress) |
  Add-Content -Path (Join-Path $backupDir 'backup-history.jsonl') -Encoding utf8

Write-Host "PASS: backup criado em $finalFile"
Write-Host "PASS: retenção de $RetentionDays dias aplicada; removidos: $($expired.Count)"
if ($mirrorFinal) {
  Write-Host "PASS: espelho SHA-256 verificado em $mirrorFinal"
  Write-Host "PASS: retenção do espelho aplicada; removidos: $($mirrorExpired.Count)"
}
