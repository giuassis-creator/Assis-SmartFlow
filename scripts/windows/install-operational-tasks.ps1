param(
  [string]$MirrorPath = 'C:\Assis-SmartFlow-Backups',
  [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
  [string]$BackupTime = '03:00',
  [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
  [string]$RestoreTime = '04:00'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Execute este script em um PowerShell 7 aberto como administrador.'
}

$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$currentUser = $identity.Name
if (-not $currentUser) {
  throw 'Não foi possível resolver o usuário atual.'
}

$monitorScript = Join-Path $root 'scripts\windows\monitor-smartflow.ps1'
$backupScript = Join-Path $root 'scripts\windows\backup-smartflow.ps1'
$restoreScript = Join-Path $root 'scripts\windows\test-restore-smartflow.ps1'
foreach ($path in @($monitorScript, $backupScript, $restoreScript)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Script obrigatório não encontrado: $path"
  }
}

$mirrorFullPath = [IO.Path]::GetFullPath($MirrorPath)
New-Item -ItemType Directory -Force -Path $mirrorFullPath | Out-Null

function New-AssisTask {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string[]]$Schedule
  )

  $arguments = @(
    '/Create',
    '/TN', $Name,
    '/TR', $Command
  ) + $Schedule + @(
    '/RU', $currentUser,
    '/IT',
    '/RL', 'HIGHEST',
    '/F'
  )

  & schtasks.exe @arguments | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao criar ou atualizar a tarefa: $Name"
  }

  & schtasks.exe /Query /TN $Name | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "A tarefa não pôde ser confirmada após a criação: $Name"
  }
}

$quotedPwsh = '"' + $pwsh + '"'
$monitorCommand = "$quotedPwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$monitorScript`""
$backupCommand = "$quotedPwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$backupScript`" -RetentionDays 30 -MirrorPath `"$mirrorFullPath`""
$restoreCommand = "$quotedPwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$restoreScript`""

New-AssisTask -Name 'Assis SmartFlow Hourly Monitor' -Command $monitorCommand -Schedule @('/SC', 'HOURLY', '/MO', '1')
New-AssisTask -Name 'Assis SmartFlow Daily Backup' -Command $backupCommand -Schedule @('/SC', 'DAILY', '/ST', $BackupTime)
New-AssisTask -Name 'Assis SmartFlow Monthly Restore Test' -Command $restoreCommand -Schedule @('/SC', 'MONTHLY', '/D', '1', '/ST', $RestoreTime)

$taskNames = @(
  'Assis SmartFlow Hourly Monitor',
  'Assis SmartFlow Daily Backup',
  'Assis SmartFlow Monthly Restore Test'
)
$tasks = foreach ($name in $taskNames) {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
  $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction Stop
  [pscustomobject]@{
    TaskName = $name
    State = $task.State
    NextRunTime = $info.NextRunTime
    Execute = $task.Actions.Execute
    Arguments = $task.Actions.Arguments
  }
}

$tasks | Format-Table TaskName, State, NextRunTime -AutoSize
Write-Host "PASS: tarefas operacionais instaladas para $currentUser."
Write-Host "PASS: backup diário=$BackupTime; restauração mensal=dia 1 às $RestoreTime; espelho=$mirrorFullPath."
