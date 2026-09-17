param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^\+?[0-9]{8,15}$')]
  [string]$TestNumber,
  [ValidateRange(180,1200)]
  [int]$WaitSeconds = 900
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml','-f','core/docker-compose.waha-setup.yml')

function Get-EnvMatch([string[]]$Lines,[string]$Name) {
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  for ($i=$Lines.Count-1; $i -ge 0; $i--) {
    if ($Lines[$i] -match $pattern) { return [pscustomobject]@{Found=$true;Index=$i;Line=$Lines[$i]} }
  }
  return [pscustomobject]@{Found=$false;Index=-1;Line=$null}
}

function Set-EnvLine([string[]]$Lines,[string]$Name,[string]$Value) {
  $match=Get-EnvMatch $Lines $Name
  if($match.Found){$Lines[$match.Index]="$Name=$Value"}else{$Lines += "$Name=$Value"}
  return @($Lines)
}

function Restore-EnvLine([string[]]$Lines,[string]$Name,$Original) {
  $match=Get-EnvMatch $Lines $Name
  if($Original.Found){
    if($match.Found){$Lines[$match.Index]=$Original.Line}else{$Lines += $Original.Line}
  }else{
    $Lines=@($Lines|Where-Object{$_ -notmatch "^\s*$([regex]::Escape($Name))\s*="})
  }
  return @($Lines)
}

function Write-EnvLines([string[]]$Lines) {
  $utf8NoBom=New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines((Resolve-Path .env),$Lines,$utf8NoBom)
}

function Get-ComposeContainer([string]$Service) {
  $out=& docker compose @compose ps -q $Service 2>$null
  if($LASTEXITCODE -ne 0){throw "Falha ao consultar $Service."}
  $id=(($out|Where-Object{$_}) -join '').Trim()
  if($id -notmatch '^[0-9a-f]{12,64}$'){throw "Container $Service não encontrado."}
  return $id
}

function Invoke-PgScalar([string]$Sql) {
  $postgres=Get-ComposeContainer 'postgres'
  $pgUser=(& docker exec $postgres printenv POSTGRES_USER 2>$null).Trim()
  $pgDatabase=(& docker exec $postgres printenv POSTGRES_DB 2>$null).Trim()
  if(-not $pgUser -or -not $pgDatabase){throw 'Configuração PostgreSQL incompleta no container.'}
  $previousErrorAction=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    $rawOut=@($Sql | & docker exec -i $postgres psql --quiet --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 --username $pgUser --dbname $pgDatabase 2>&1)
    $exitCode=$LASTEXITCODE
  } finally { $ErrorActionPreference=$previousErrorAction }
  if($exitCode -ne 0){throw "psql failed with exit code $exitCode."}
  $values=@($rawOut|Where-Object{$_ -is [string] -and $_ -notmatch '^(NOTICE|WARNING):' -and -not [string]::IsNullOrWhiteSpace($_)}|ForEach-Object{$_.ToString().Trim()})
  if($values.Count -gt 1){throw 'Consulta retornou saída não escalar.'}
  return ($values -join '').Trim()
}

function Restart-GateServices {
  & docker compose @compose up -d --no-deps --force-recreate provider-gateway waha | Out-Host
  if($LASTEXITCODE -ne 0){throw 'Falha ao recriar provider-gateway/WAHA.'}
}

if(-not(Test-Path .env)){throw '.env não encontrado.'}
$originalLines=@(Get-Content .env)
$originalEnabled=Get-EnvMatch $originalLines 'WAHA_REAL_E2E_ENABLED'
$originalNumber=Get-EnvMatch $originalLines 'WAHA_REAL_E2E_TEST_NUMBER'
$marker='ASSIS-E2E-'+[guid]::NewGuid().ToString('N')
$completed=$false

try {
  $temporary=Set-EnvLine $originalLines 'WAHA_REAL_E2E_ENABLED' 'true'
  $temporary=Set-EnvLine $temporary 'WAHA_REAL_E2E_TEST_NUMBER' $TestNumber
  Write-EnvLines $temporary

  Write-Host '=== Assis SmartFlow WAHA - E2E real autorizado ==='
  Write-Host 'INFO: trava temporária limitada ao número autorizado; o número não será exibido.'
  & "$PSScriptRoot\deploy-waha-provider.ps1"
  if($LASTEXITCODE -ne 0){throw 'Implantação WAHA falhou antes do E2E real.'}

  $gateway=Get-ComposeContainer 'provider-gateway'
  $healthRaw=& docker exec $gateway python -c "import json,urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=5).read().decode())" 2>$null
  if($LASTEXITCODE -ne 0){throw 'Falha ao consultar health do provider-gateway.'}
  $health=($healthRaw -join '')|ConvertFrom-Json
  if($health.waha_real_e2e_enabled -ne $true -or $health.waha_real_e2e_ready -ne $true){throw 'Trava E2E real não ficou pronta.'}

  Write-Host 'Envie agora, pelo WhatsApp autorizado, exatamente esta mensagem para o número conectado ao WAHA:'
  Write-Host $marker
  Write-Host "Aguardando entrada e resposta automática por até $WaitSeconds segundos..."

  $deadline=(Get-Date).AddSeconds($WaitSeconds)
  $inboundId=$null
  while((Get-Date) -lt $deadline){
    $markerEsc=$marker.Replace("'","''")
    $inboundId=Invoke-PgScalar "SELECT id::text FROM messages WHERE direction='in' AND body='$markerEsc' ORDER BY created_at DESC LIMIT 1;"
    if($inboundId){break}
    Start-Sleep -Seconds 3
  }
  if(-not $inboundId){throw 'A mensagem autorizada não foi persistida dentro do prazo.'}

  $idem="real-e2e-reply:$inboundId"
  $idemEsc=$idem.Replace("'","''")
  $outboundCount='0'
  while((Get-Date) -lt $deadline){
    $outboundCount=Invoke-PgScalar "SELECT count(*)::text FROM messages WHERE direction='out' AND idempotency_key='$idemEsc';"
    if($outboundCount -eq '1'){break}
    Start-Sleep -Seconds 3
  }
  if($outboundCount -ne '1'){throw 'Resposta automática real não foi persistida exatamente uma vez dentro do prazo.'}

  $inboundCount=Invoke-PgScalar "SELECT count(*)::text FROM messages WHERE direction='in' AND body='$markerEsc';"
  if($inboundCount -ne '1'){throw "Idempotência de entrada falhou: $inboundCount registros."}
  Write-Host 'PASS: entrada WAHA real foi autenticada e persistida exatamente uma vez.'
  Write-Host 'PASS: Maya/contexto/RAG concluíram e a resposta WAHA real foi persistida exatamente uma vez.'
  Write-Host 'PASS: E2E real autorizado concluído.'
  $completed=$true
} finally {
  $current=@(Get-Content .env)
  $current=Restore-EnvLine $current 'WAHA_REAL_E2E_ENABLED' $originalEnabled
  $current=Restore-EnvLine $current 'WAHA_REAL_E2E_TEST_NUMBER' $originalNumber
  Write-EnvLines $current
  try {
    Restart-GateServices
    Write-Host 'PASS: trava temporária E2E foi restaurada/desativada e serviços foram recriados.'
  } catch {
    Write-Warning 'A configuração do arquivo foi restaurada, mas a recriação dos serviços falhou. Não aceite novas mensagens até executar docker compose up para provider-gateway e WAHA.'
    if($completed){throw}
  }
}
