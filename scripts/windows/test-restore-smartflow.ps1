$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

$backup = Get-ChildItem -LiteralPath (Join-Path $root '.local\backups') -Filter 'smartflow-*.dump' -File |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
if (-not $backup) { throw 'Nenhum backup smartflow-*.dump foi encontrado.' }
if ($backup.Length -lt 1024) { throw 'O backup mais recente está vazio ou inválido.' }

$compose = @('--env-file', '.env', '-f', 'core/docker-compose.yml', '-f', 'core/docker-compose.desktop.yml')
$postgresContainer = ((& docker compose @compose ps -q postgres 2>$null) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or -not $postgresContainer) {
  throw 'Container PostgreSQL não está em execução.'
}

$pgUser = ((& docker exec $postgresContainer printenv POSTGRES_USER 2>$null) -join '').Trim()
$productionDatabase = ((& docker exec $postgresContainer printenv POSTGRES_DB 2>$null) -join '').Trim()
if (-not $pgUser -or -not $productionDatabase) {
  throw 'Configuração PostgreSQL incompleta no container.'
}

$suffix = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + $PID
$restoreDatabase = "assis_restore_$suffix"
if ($restoreDatabase -notmatch '^assis_restore_[0-9]{14}_[0-9]+$') {
  throw 'Nome do banco temporário não passou na validação de segurança.'
}
if ($restoreDatabase -eq $productionDatabase) {
  throw 'O banco temporário não pode coincidir com o banco de produção.'
}

$containerArchive = "/tmp/$($backup.Name).restore-test"
$tempCreated = $false
try {
  & docker cp $backup.FullName "$($postgresContainer):$containerArchive"
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao copiar o backup para o container.' }

  & docker exec $postgresContainer createdb --username $pgUser $restoreDatabase
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao criar o banco temporário.' }
  $tempCreated = $true

  & docker exec $postgresContainer pg_restore `
    --username $pgUser `
    --dbname $restoreDatabase `
    --no-owner `
    --no-privileges `
    --exit-on-error `
    $containerArchive
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao restaurar o backup no banco temporário.' }

  $tableCount = ((& docker exec $postgresContainer psql `
    --username $pgUser `
    --dbname $restoreDatabase `
    --tuples-only --no-align `
    --command "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>$null) -join '').Trim()
  if ($LASTEXITCODE -ne 0 -or [int]$tableCount -lt 1) {
    throw "Restauração não produziu tabelas públicas (count=$tableCount)."
  }

  $workflowCount = ((& docker exec $postgresContainer psql `
    --username $pgUser `
    --dbname $restoreDatabase `
    --tuples-only --no-align `
    --command 'SELECT count(*) FROM workflow_entity;' 2>$null) -join '').Trim()
  if ($LASTEXITCODE -ne 0 -or [int]$workflowCount -lt 1) {
    throw "Restauração não preservou workflows (count=$workflowCount)."
  }

  Write-Host "PASS: backup restaurado em banco temporário."
  Write-Host "PASS: tabelas públicas=$tableCount; workflows=$workflowCount."
} finally {
  if ($tempCreated) {
    if ($restoreDatabase -notmatch '^assis_restore_[0-9]{14}_[0-9]+$' -or $restoreDatabase -eq $productionDatabase) {
      throw 'Limpeza interrompida: nome do banco temporário não é seguro.'
    }
    & docker exec $postgresContainer dropdb --username $pgUser --if-exists --force $restoreDatabase 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Não foi possível remover automaticamente o banco temporário $restoreDatabase."
    } else {
      Write-Host "PASS: banco temporário removido."
    }
  }
  & docker exec $postgresContainer rm -f $containerArchive 2>$null | Out-Null
}
