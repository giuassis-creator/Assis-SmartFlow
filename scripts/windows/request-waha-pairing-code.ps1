param([Parameter(Mandatory=$true)][ValidatePattern('^[0-9]{8,15}$')][string]$PhoneNumber)
$ErrorActionPreference='Stop'
$root=Resolve-Path "$PSScriptRoot\..\..";Set-Location $root
function Read-EnvValue([string]$Name){$line=Get-Content .env|Where-Object{$_ -match "^\s*$([regex]::Escape($Name))\s*="}|Select-Object -Last 1;if(-not $line){return $null};$v=($line -split '=',2)[1].Trim();if(($v.StartsWith('"')-and$v.EndsWith('"'))-or($v.StartsWith("'")-and$v.EndsWith("'"))){$v=$v.Substring(1,$v.Length-2)};return $v}
if(-not(Test-Path .env)){throw '.env não encontrado.'}
$session=Read-EnvValue 'WAHA_SESSION';if([string]::IsNullOrWhiteSpace($session)){$session='default'}
$apiKey=Read-EnvValue 'WAHA_API_KEY';if([string]::IsNullOrWhiteSpace($apiKey)){throw 'WAHA_API_KEY não encontrado.'}
$headers=@{'X-Api-Key'=$apiKey;Accept='application/json';'Content-Type'='application/json'}
$sessionUrl='http://127.0.0.1:3000/api/sessions/'+[uri]::EscapeDataString($session)
$state=Invoke-RestMethod -Uri $sessionUrl -Headers $headers -TimeoutSec 10
if($state.engine.engine -ne 'GOWS'){throw "Pareamento por este fluxo exige GOWS; engine atual=$($state.engine.engine)."}
if($state.status -eq 'WORKING'){Write-Host 'PASS: sessão já está WORKING; nenhum novo pareamento foi solicitado.';exit 0}

if($state.status -eq 'FAILED'){
  Write-Host "RECOVERY: sessão '$session' está FAILED; reiniciando sem logout e sem apagar dados..."
  $restartUrl=$sessionUrl+'/restart'
  $rr=Invoke-WebRequest -Uri $restartUrl -Headers $headers -Method Post -Body '{}' -SkipHttpErrorCheck -TimeoutSec 30
  if($rr.StatusCode -lt 200 -or $rr.StatusCode -ge 300){throw "Falha ao reiniciar sessão (HTTP $($rr.StatusCode)): $($rr.Content)"}
  $deadline=(Get-Date).AddSeconds(60)
  do{
    Start-Sleep 2
    $state=Invoke-RestMethod -Uri $sessionUrl -Headers $headers -TimeoutSec 10
    Write-Host "Estado pós-restart: $($state.status)"
    if($state.status -in @('SCAN_QR_CODE','WORKING','PASSKEY_REQUIRED','PASSKEY_CONFIRMATION_REQUIRED')){break}
    if($state.status -eq 'FAILED' -and (Get-Date) -gt $deadline.AddSeconds(-40)){break}
  }while((Get-Date)-lt $deadline)
}

if($state.status -eq 'WORKING'){Write-Host 'PASS: sessão ficou WORKING durante a recuperação.';exit 0}
if($state.status -eq 'PASSKEY_REQUIRED'){Write-Host 'READY: sessão exige passkey/WebAuthn antes do código.';exit 0}
if($state.status -eq 'PASSKEY_CONFIRMATION_REQUIRED'){Write-Host 'READY: sessão exige confirmação de passkey.';exit 0}
if($state.status -ne 'SCAN_QR_CODE'){
  throw "Não é seguro solicitar código no estado '$($state.status)'. Nenhum logout ou exclusão foi executado."
}

$url='http://127.0.0.1:3000/api/'+[uri]::EscapeDataString($session)+'/auth/request-code'
$body=@{phoneNumber=$PhoneNumber}|ConvertTo-Json -Compress
$r=Invoke-WebRequest -Uri $url -Headers $headers -Method Post -Body $body -SkipHttpErrorCheck -TimeoutSec 30
if($r.StatusCode -lt 200 -or $r.StatusCode -ge 300){throw "Falha ao solicitar código (HTTP $($r.StatusCode)): $($r.Content)"}
Write-Host '=== CÓDIGO DE PAREAMENTO WAHA/GOWS ==='
try {$obj=$r.Content|ConvertFrom-Json;$code=$obj.code;if(-not $code){$code=$obj.pairingCode};if($code){Write-Host "Código: $code"}else{Write-Host $r.Content}} catch {Write-Host $r.Content}
Write-Host 'No WhatsApp do telefone, use Dispositivos conectados > Conectar um dispositivo > Conectar com número de telefone e informe o código.'
Write-Host 'Aguardando mudança de estado por até 120 segundos...'
$deadline=(Get-Date).AddSeconds(120);$last=''
do{Start-Sleep 2;$state=Invoke-RestMethod -Uri $sessionUrl -Headers $headers -TimeoutSec 10;if($state.status -ne $last){Write-Host "Estado: $($state.status)";$last=$state.status};if($state.status -in @('WORKING','PASSKEY_REQUIRED','PASSKEY_CONFIRMATION_REQUIRED','FAILED')){break}}while((Get-Date)-lt $deadline)
if($state.status -eq 'WORKING'){Write-Host 'PASS: sessão WAHA está WORKING.';exit 0}
if($state.status -eq 'PASSKEY_REQUIRED'){
  Write-Host 'READY: WhatsApp exige passkey/WebAuthn. Isto confirma que QR/código não são suficientes para esta conta.'
  Write-Host 'Use o Dashboard WAHA local com a extensão oficial para assinar o desafio no contexto https://web.whatsapp.com.'
  Write-Host 'Depois execute novamente continue-waha-homologation.ps1.'
  exit 0
}
if($state.status -eq 'PASSKEY_CONFIRMATION_REQUIRED'){
  Write-Host 'READY: passkey aceita e confirmação adicional exigida. Conclua a confirmação no Dashboard WAHA e rode novamente a homologação.'
  exit 0
}
if($state.status -eq 'FAILED'){throw 'Pareamento terminou em FAILED. Não repita automaticamente; capture os logs WAHA desta tentativa.'}
Write-Host "INFO: estado final após janela de observação: $($state.status). Não será feito logout nem exclusão automática."
