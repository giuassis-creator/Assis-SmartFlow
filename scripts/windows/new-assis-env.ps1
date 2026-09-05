param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$envFile = Join-Path $root '.env'
if ((Test-Path $envFile) -and -not $Force) {
  Write-Host '.env já existe; mantendo configuração atual.'
  exit 0
}
Copy-Item '.env.example' $envFile -Force
function New-HexSecret([int]$Bytes = 32) {
  $data = New-Object byte[] $Bytes
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($data)
  return [Convert]::ToHexString($data).ToLowerInvariant()
}
$content = Get-Content $envFile -Raw
$content = $content.Replace('POSTGRES_PASSWORD=CHANGE_ME_LONG_RANDOM', 'POSTGRES_PASSWORD=' + (New-HexSecret 24))
$content = $content.Replace('REDIS_PASSWORD=CHANGE_ME_LONG_RANDOM', 'REDIS_PASSWORD=' + (New-HexSecret 24))
$content = $content.Replace('N8N_ENCRYPTION_KEY=CHANGE_ME_64_CHAR_RANDOM', 'N8N_ENCRYPTION_KEY=' + (New-HexSecret 32))
$content = [regex]::Replace($content, 'INTERNAL_AGENT_TOKEN=CHANGE_ME[^\r\n]*', 'INTERNAL_AGENT_TOKEN=' + (New-HexSecret 32))
Set-Content -Path $envFile -Value $content -Encoding utf8
Write-Host '.env criado com segredos locais aleatórios. Não faça commit desse arquivo.'
