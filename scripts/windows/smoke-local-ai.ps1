$ErrorActionPreference = 'Stop'
function Wait-Http([string]$Url, [int]$Attempts = 60) {
  for ($i=1; $i -le $Attempts; $i++) {
    try { return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 5 }
    catch { Start-Sleep -Seconds 2 }
  }
  throw "Endpoint não ficou pronto: $Url"
}
Write-Host 'Ollama...'
Wait-Http 'http://localhost:11434/api/tags' | Out-Null
$body = @{ model='qwen3:4b-instruct'; stream=$false; messages=@(@{role='user';content='Responda apenas: ok'}) } | ConvertTo-Json -Depth 8
$r = Invoke-RestMethod -Uri 'http://localhost:11434/api/chat' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
if (-not $r.message.content) { throw 'Ollama não retornou conteúdo.' }
Write-Host 'STT...'
Wait-Http 'http://localhost:8000/health' | Out-Null
Write-Host 'TTS...'
Wait-Http 'http://localhost:7860/tts/status' | Out-Null
$tts = @{ text='Olá. Eu sou a Maya, secretária da empresa.'; voice='pf_dora'; output_format='wav' } | ConvertTo-Json
Invoke-WebRequest -Uri 'http://localhost:7860/tts/generate' -Method Post -ContentType 'application/json' -Body $tts -OutFile (Join-Path $env:TEMP 'assis-maya-smoke.wav') -TimeoutSec 180 | Out-Null
if ((Get-Item (Join-Path $env:TEMP 'assis-maya-smoke.wav')).Length -lt 1000) { throw 'TTS gerou áudio vazio ou inválido.' }
Write-Host 'Qdrant...'
Wait-Http 'http://localhost:6333/readyz' | Out-Null
Write-Host 'PASS: IA local e serviços auxiliares responderam.'
