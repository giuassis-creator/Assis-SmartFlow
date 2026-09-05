$ErrorActionPreference='Stop'
$collection = 'assis_knowledge'
$base='http://localhost:6333'
for ($i=0; $i -lt 60; $i++) {
  try { Invoke-RestMethod "$base/readyz" -TimeoutSec 3 | Out-Null; break }
  catch { Start-Sleep -Seconds 2 }
}
try {
  Invoke-RestMethod "$base/collections/$collection" -TimeoutSec 5 | Out-Null
  Write-Host "Qdrant collection '$collection' já existe."
} catch {
  $dim = if ($env:EMBEDDING_DIM) { [int]$env:EMBEDDING_DIM } else { 768 }
  $body = @{ vectors = @{ size=$dim; distance='Cosine' } } | ConvertTo-Json -Depth 4
  Invoke-RestMethod "$base/collections/$collection" -Method Put -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
  Write-Host "Qdrant collection '$collection' criada com dimensão $dim."
}
