$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml')

function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar o serviço ${Service}:`n$($out -join "`n")"
  }
  return (($out | Where-Object { $_ }) -join '').Trim()
}

$envPath = Join-Path $root '.env'
if (-not (Test-Path $envPath)) { throw '.env não encontrado.' }

$tokenLine = Get-Content $envPath | Where-Object { $_ -match '^\s*INTERNAL_AGENT_TOKEN\s*=' } | Select-Object -Last 1
if (-not $tokenLine) { throw 'INTERNAL_AGENT_TOKEN não encontrado no .env.' }
$token = ($tokenLine -split '=',2)[1].Trim()
if (($token.StartsWith('"') -and $token.EndsWith('"')) -or ($token.StartsWith("'") -and $token.EndsWith("'"))) {
  $token = $token.Substring(1,$token.Length-2)
}
if ([string]::IsNullOrWhiteSpace($token) -or $token -eq 'CHANGE_ME_LONG_RANDOM_INTERNAL_TOKEN' -or $token.Length -lt 32) {
  throw 'INTERNAL_AGENT_TOKEN inválido ou fraco. Gere um segredo longo antes de publicar o núcleo.'
}

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
  $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($token))
} finally {
  $sha.Dispose()
}
$tokenHash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
$postgresContainer = Get-ComposeContainer 'postgres'
if (-not $postgresContainer) { throw 'Container postgres não está em execução.' }

$sql = @"
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS internal_auth_secrets (
  name text PRIMARY KEY,
  token_sha256 text NOT NULL CHECK (token_sha256 ~ '^[0-9a-f]{64}$'),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO internal_auth_secrets(name,token_sha256,updated_at)
VALUES ('core-internal-agent','$tokenHash',CURRENT_TIMESTAMP)
ON CONFLICT(name)
DO UPDATE SET token_sha256=EXCLUDED.token_sha256,updated_at=CURRENT_TIMESTAMP;
"@

$result = & docker exec --env "ASSIS_SQL=$sql" $postgresContainer sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$ASSIS_SQL"' 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao configurar autenticação interna:`n$($result -join "`n")"
}

Write-Host 'PASS: autenticação interna configurada com hash SHA-256; token bruto permanece somente no .env.'
