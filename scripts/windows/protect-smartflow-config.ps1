param(
  [Parameter(Mandatory)]
  [ValidateSet('Backup', 'Verify', 'Restore')]
  [string]$Mode,

  [Parameter(Mandatory)]
  [string]$ArchivePath,

  [string]$DestinationPath,

  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
$magic = 'ASCFG001'
$iterations = 210000

function ConvertTo-PlainText([Security.SecureString]$SecureValue) {
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

function Read-Password([switch]$Confirm) {
  $first = ConvertTo-PlainText (Read-Host 'Senha do backup criptografado' -AsSecureString)
  if ([string]::IsNullOrWhiteSpace($first) -or $first.Length -lt 12) {
    throw 'Use uma senha com pelo menos 12 caracteres.'
  }
  if ($Confirm) {
    $second = ConvertTo-PlainText (Read-Host 'Confirme a senha' -AsSecureString)
    if ($first -cne $second) {
      throw 'As senhas não coincidem.'
    }
    $second = $null
  }
  return $first
}

function Get-Key([string]$Password, [byte[]]$Salt) {
  $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new(
    $Password,
    $Salt,
    $iterations,
    [Security.Cryptography.HashAlgorithmName]::SHA256
  )
  try {
    return $derive.GetBytes(32)
  } finally {
    $derive.Dispose()
  }
}

function Protect-Bytes([byte[]]$PlainBytes, [string]$Password) {
  $salt = [byte[]]::new(16)
  $nonce = [byte[]]::new(12)
  [Security.Cryptography.RandomNumberGenerator]::Fill($salt)
  [Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
  $key = Get-Key $Password $salt
  $cipher = [byte[]]::new($PlainBytes.Length)
  $tag = [byte[]]::new(16)
  try {
    $aes = [Security.Cryptography.AesGcm]::new($key, 16)
    try {
      $aes.Encrypt($nonce, $PlainBytes, $cipher, $tag)
    } finally {
      $aes.Dispose()
    }
  } finally {
    [Array]::Clear($key, 0, $key.Length)
  }

  $header = [Text.Encoding]::ASCII.GetBytes($magic)
  $output = [byte[]]::new($header.Length + $salt.Length + $nonce.Length + $tag.Length + $cipher.Length)
  $offset = 0
  foreach ($part in @($header, $salt, $nonce, $tag, $cipher)) {
    [Buffer]::BlockCopy($part, 0, $output, $offset, $part.Length)
    $offset += $part.Length
  }
  return $output
}

function Unprotect-Bytes([byte[]]$ProtectedBytes, [string]$Password) {
  if ($ProtectedBytes.Length -lt 53) {
    throw 'Arquivo criptografado inválido ou truncado.'
  }
  if ([Text.Encoding]::ASCII.GetString($ProtectedBytes, 0, 8) -ne $magic) {
    throw 'Formato de backup criptografado não reconhecido.'
  }

  $salt = $ProtectedBytes[8..23]
  $nonce = $ProtectedBytes[24..35]
  $tag = $ProtectedBytes[36..51]
  $cipher = $ProtectedBytes[52..($ProtectedBytes.Length - 1)]
  $plain = [byte[]]::new($cipher.Length)
  $key = Get-Key $Password $salt
  try {
    $aes = [Security.Cryptography.AesGcm]::new($key, 16)
    try {
      $aes.Decrypt($nonce, $cipher, $tag, $plain)
    } finally {
      $aes.Dispose()
    }
  } catch [Security.Cryptography.AuthenticationTagMismatchException] {
    throw 'Senha incorreta ou arquivo criptografado alterado.'
  } finally {
    [Array]::Clear($key, 0, $key.Length)
  }
  return $plain
}

if ($Mode -eq 'Backup') {
  $source = Join-Path $root '.env'
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'Arquivo .env não encontrado.'
  }

  $envBytes = [IO.File]::ReadAllBytes($source)
  if ($envBytes.Length -lt 1) {
    throw 'Arquivo .env está vazio.'
  }

  $payload = [ordered]@{
    format = 1
    created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    files = [ordered]@{
      '.env' = [Convert]::ToBase64String($envBytes)
    }
  }
  $plainBytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 4 -Compress))
  $password = Read-Password -Confirm
  try {
    $protected = Protect-Bytes $plainBytes $password
  } finally {
    $password = $null
    [Array]::Clear($plainBytes, 0, $plainBytes.Length)
  }

  $archiveFullPath = [IO.Path]::GetFullPath($ArchivePath)
  $archiveDirectory = Split-Path -Parent $archiveFullPath
  New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
  $partial = "$archiveFullPath.partial"
  try {
    [IO.File]::WriteAllBytes($partial, $protected)
    Move-Item -LiteralPath $partial -Destination $archiveFullPath -Force
  } finally {
    if (Test-Path -LiteralPath $partial) {
      Remove-Item -LiteralPath $partial -Force
    }
  }

  Write-Host "PASS: configuração criptografada criada em $archiveFullPath"
  Write-Host "Guarde a senha separadamente; ela não pode ser recuperada pelo projeto."
  exit 0
}

if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
  throw 'Arquivo criptografado não encontrado.'
}
$password = Read-Password
try {
  $plainBytes = Unprotect-Bytes ([IO.File]::ReadAllBytes($ArchivePath)) $password
  $payload = [Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json
} finally {
  $password = $null
  if ($plainBytes) {
    [Array]::Clear($plainBytes, 0, $plainBytes.Length)
  }
}
if ($payload.format -ne 1 -or -not $payload.files.'.env') {
  throw 'Conteúdo criptografado inválido.'
}
$envBytes = [Convert]::FromBase64String([string]$payload.files.'.env')
if ($envBytes.Length -lt 1) {
  throw 'O .env recuperado está vazio.'
}
$sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($envBytes))

if ($Mode -eq 'Verify') {
  Write-Host "PASS: senha e integridade criptográfica confirmadas."
  Write-Host "PASS: .env recuperável; bytes=$($envBytes.Length); sha256=$sha256"
  [Array]::Clear($envBytes, 0, $envBytes.Length)
  exit 0
}

if (-not $DestinationPath) {
  $DestinationPath = Join-Path $root '.env.restored'
}
$destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)
$productionEnv = [IO.Path]::GetFullPath((Join-Path $root '.env'))
if ($destinationFullPath -eq $productionEnv -and -not $Force) {
  throw 'Use -Force para substituir o .env ativo.'
}
if ((Test-Path -LiteralPath $destinationFullPath) -and -not $Force) {
  throw "O destino já existe: $destinationFullPath. Use -Force para substituir."
}
[IO.File]::WriteAllBytes($destinationFullPath, $envBytes)
[Array]::Clear($envBytes, 0, $envBytes.Length)
Write-Host "PASS: configuração restaurada em $destinationFullPath"
Write-Host "PASS: sha256=$sha256"
