param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^\+?[0-9]{8,15}$')]
  [string]$TestNumber
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

function Read-EnvLines {
  if (-not (Test-Path .env)) { throw '.env não encontrado.' }
  return @(Get-Content .env)
}

function Get-EnvMatch([string[]]$Lines,[string]$Name) {
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  for ($i=$Lines.Count-1; $i -ge 0; $i--) {
    if ($Lines[$i] -match $pattern) {
      return [pscustomobject]@{ Found=$true; Index=$i; Line=$Lines[$i] }
    }
  }
  return [pscustomobject]@{ Found=$false; Index=-1; Line=$null }
}

$lines = Read-EnvLines
$match = Get-EnvMatch $lines 'WAHA_TEST_NUMBER'
$hadOriginal = $match.Found
$originalLine = $match.Line

try {
  if ($match.Found) {
    $lines[$match.Index] = "WAHA_TEST_NUMBER=$TestNumber"
  } else {
    $lines += "WAHA_TEST_NUMBER=$TestNumber"
  }
  Set-Content .env -Value $lines -Encoding utf8

  Write-Host '=== Assis SmartFlow WAHA - smoke outbound autorizado ==='
  Write-Host 'INFO: WAHA_TEST_NUMBER foi definido temporariamente apenas para esta homologação.'
  Write-Host 'INFO: o número não será exibido e será restaurado/removido ao final.'

  & "$PSScriptRoot\finalize-waha-homologation.ps1"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
  $current = @(Get-Content .env)
  $currentMatch = Get-EnvMatch $current 'WAHA_TEST_NUMBER'
  if ($hadOriginal) {
    if ($currentMatch.Found) {
      $current[$currentMatch.Index] = $originalLine
    } else {
      $current += $originalLine
    }
  } else {
    $current = @($current | Where-Object { $_ -notmatch '^\s*WAHA_TEST_NUMBER\s*=' })
  }
  Set-Content .env -Value $current -Encoding utf8
  Write-Host 'PASS: configuração temporária WAHA_TEST_NUMBER foi restaurada.'
}
