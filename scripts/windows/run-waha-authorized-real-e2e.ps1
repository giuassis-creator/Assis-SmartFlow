param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^\+[1-9][0-9]{10,14}$')]
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

function Warm-OllamaPlanner([int]$KeepAliveSeconds) {
  $n8n=Get-ComposeContainer 'n8n'
  $model=(& docker exec $n8n printenv OLLAMA_CHAT_MODEL 2>$null).Trim()
  if([string]::IsNullOrWhiteSpace($model) -or $model -notmatch '^[A-Za-z0-9._:/-]+$'){throw 'Modelo Ollama de chat inválido para aquecimento.'}
  $warmScript=@'
const model=process.env.ASSIS_MODEL;
const keepAlive=process.env.ASSIS_KEEP_ALIVE+'s';
const body={model,stream:false,keep_alive:keepAlive,options:{temperature:0,num_predict:4,num_ctx:2048},messages:[{role:'user',content:'Responda somente: OK'}]};
fetch('http://ollama:11434/api/chat',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(240000)})
  .then(async response=>{const result=await response.json();if(!response.ok||result.done!==true)process.exit(2);console.log('READY')})
  .catch(()=>process.exit(3));
'@
  $warmOut=& docker exec --env "ASSIS_MODEL=$model" --env "ASSIS_KEEP_ALIVE=$KeepAliveSeconds" $n8n node -e $warmScript 2>&1
  if($LASTEXITCODE -ne 0 -or (($warmOut|ForEach-Object{$_.ToString()}) -join '') -notmatch 'READY'){throw 'Falha ao aquecer o planner Ollama antes da janela E2E real.'}
  Write-Host 'PASS: planner Ollama aquecido e mantido residente durante a janela E2E.'
}

function Protect-DiagnosticText([string]$Text,[string]$Marker) {
  if($null -eq $Text){return ''}
  $safe=$Text
  if($Marker){$safe=$safe.Replace($Marker,'[REDACTED_MARKER]')}
  $safe=[regex]::Replace($safe,'(?<![0-9])\+?[0-9]{8,15}(?![0-9])','[REDACTED_NUMBER]')
  $safe=[regex]::Replace($safe,'(?im)((?:authorization|x-api-key|x-assis-[a-z0-9-]+|api[_-]?key|token|secret|password|credential)\s*[:=]\s*)[^\s,;]+','$1[REDACTED]')
  return $safe
}

function Save-FailureDiagnostics([string]$Marker,[System.Management.Automation.ErrorRecord]$Failure) {
  $stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
  $directory=Join-Path $root ".local\waha-real-e2e\$stamp"
  [System.IO.Directory]::CreateDirectory($directory)|Out-Null
  $utf8NoBom=New-Object System.Text.UTF8Encoding($false)
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try {
    $markerHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Marker)))).Replace('-','').ToLowerInvariant()
  } finally {$sha.Dispose()}

  $services=[ordered]@{}
  foreach($service in @('n8n','postgres','waha','provider-gateway')){
    try {
      $container=Get-ComposeContainer $service
      $stateRaw=& docker inspect --format '{{json .State}}' $container 2>$null
      if($LASTEXITCODE -ne 0){throw "docker inspect failed for $service"}
      $state=($stateRaw -join '')|ConvertFrom-Json
      $healthStatus=$null
      if($state.Health){$healthStatus=$state.Health.Status}
      $services[$service]=[ordered]@{
        status=$state.Status
        running=[bool]$state.Running
        restarting=[bool]$state.Restarting
        exit_code=[int]$state.ExitCode
        oom_killed=[bool]$state.OOMKilled
        health=$healthStatus
      }
      $logLines=@(& docker logs --since 30m --tail 400 $container 2>&1|ForEach-Object{$_.ToString()}|Where-Object{$_ -match '(?i)error|timeout|unauthorized|webhook|canonical|maya|agent runtime|outbound|status code|session|health|restart|oom'})
      $safeLogs=Protect-DiagnosticText ($logLines -join [Environment]::NewLine) $Marker
      [System.IO.File]::WriteAllText((Join-Path $directory "$service.log"),$safeLogs,$utf8NoBom)
    } catch {
      $services[$service]=[ordered]@{diagnostic_error='collection_failed'}
    }
  }

  $message=Protect-DiagnosticText $Failure.Exception.Message $Marker
  if($message.Length -gt 500){$message=$message.Substring(0,500)}
  $summary=[ordered]@{
    captured_at_utc=(Get-Date).ToUniversalTime().ToString('o')
    marker_sha256=$markerHash
    failure_type=$Failure.Exception.GetType().FullName
    failure_message=$message
    services=$services
    privacy=[ordered]@{
      env_copied=$false
      payloads_exported=$false
      phone_numbers_redacted=$true
      marker_redacted=$true
    }
  }
  [System.IO.File]::WriteAllText((Join-Path $directory 'summary.json'),($summary|ConvertTo-Json -Depth 8),$utf8NoBom)
  Write-Host "INFO: diagnóstico sanitizado preservado antes do cleanup em $directory"
}

if(-not(Test-Path .env)){throw '.env não encontrado.'}
$originalLines=@(Get-Content .env)
$marker='ASSIS-E2E-'+[guid]::NewGuid().ToString('N')
$completed=$false
$primaryFailure=$null
$cleanupFailure=$null

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

  Warm-OllamaPlanner ($WaitSeconds + 300)
  $windowStart=(Get-Date).ToUniversalTime().ToString('o')
  $windowStartEsc=$windowStart.Replace("'","''")

  Write-Host 'Envie agora, pelo WhatsApp autorizado, exatamente esta mensagem para o número conectado ao WAHA:'
  Write-Host $marker
  Write-Host "Aguardando entrada e resposta automática por até $WaitSeconds segundos..."

  $deadline=(Get-Date).AddSeconds($WaitSeconds)
  $inboundId=$null
  while((Get-Date) -lt $deadline){
    $inboundId=Invoke-PgScalar "SELECT id::text FROM messages WHERE direction='in' AND payload->>'real_e2e'='true' AND created_at >= '$windowStartEsc'::timestamptz ORDER BY created_at ASC LIMIT 1;"
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

  $inboundIdEsc=$inboundId.Replace("'","''")
  $inboundCount=Invoke-PgScalar "SELECT count(*)::text FROM messages WHERE id='$inboundIdEsc'::uuid AND direction='in' AND payload->>'real_e2e'='true';"
  if($inboundCount -ne '1'){throw "Idempotência de entrada falhou: $inboundCount registros."}
  Write-Host 'PASS: entrada WAHA real foi autenticada e persistida exatamente uma vez.'
  Write-Host 'PASS: Maya/contexto/RAG concluíram e a resposta WAHA real foi persistida exatamente uma vez.'
  Write-Host 'PASS: E2E real autorizado concluído.'
  $completed=$true
} catch {
  $primaryFailure=$_
  try {Save-FailureDiagnostics -Marker $marker -Failure $_}
  catch {Write-Warning 'Falha ao preservar o diagnóstico sanitizado antes do cleanup.'}
} finally {
  $current=@(Get-Content .env)
  # This is a temporary homologation gate. Fail closed unconditionally instead
  # of restoring a possibly stale or unsafe previous value.
  $current=Set-EnvLine $current 'WAHA_REAL_E2E_ENABLED' 'false'
  $current=Set-EnvLine $current 'WAHA_REAL_E2E_TEST_NUMBER' ''
  Write-EnvLines $current
  try {
    Restart-GateServices
    $cleanupDeadline=(Get-Date).AddSeconds(90)
    $cleanupVerified=$false
    do {
      try {
        $gateway=Get-ComposeContainer 'provider-gateway'
        $healthRaw=& docker exec $gateway python -c "import json,urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=5).read().decode())" 2>$null
        if($LASTEXITCODE -eq 0){
          $health=($healthRaw -join '')|ConvertFrom-Json
          if($health.waha_real_e2e_enabled -eq $false -and $health.waha_real_e2e_ready -eq $false){$cleanupVerified=$true;break}
        }
      } catch {}
      Start-Sleep -Seconds 3
    } while((Get-Date) -lt $cleanupDeadline)
    if(-not $cleanupVerified){throw 'A trava E2E real não foi confirmada como desativada após o cleanup.'}
    Write-Host 'PASS: trava temporária E2E foi desativada, número removido e serviços foram recriados.'
  } catch {
    $cleanupFailure=$_
    Write-Warning 'A configuração do arquivo foi forçada para desativada, mas a recriação/verificação dos serviços falhou. Não aceite novas mensagens até executar docker compose up para provider-gateway e WAHA.'
  }
}

if($cleanupFailure){throw $cleanupFailure}
if($primaryFailure){throw $primaryFailure}
