$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root
$compose = @('--env-file','.env','-f','core/docker-compose.yml','-f','core/docker-compose.desktop.yml','-f','core/docker-compose.waha-setup.yml')

function Read-EnvValue([string]$Name) {
  $line = Get-Content .env | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -Last 1
  if (-not $line) { return $null }
  $value = ($line -split '=',2)[1].Trim()
  if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) { $value=$value.Substring(1,$value.Length-2) }
  return $value
}
function Get-ComposeContainer([string]$Service) {
  $out = & docker compose @compose ps -q $Service 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Falha ao consultar ${Service}." }
  $id=(($out|Where-Object{$_})-join '').Trim()
  if(-not $id){throw "Container ${Service} não encontrado."}
  return $id
}
function Invoke-N8n([string]$Path,[string]$Token,[string]$Body,[bool]$HeaderToken=$true) {
  $n8n=Get-ComposeContainer 'n8n'
  $js=@'
const path=process.env.ASSIS_PATH;
const token=process.env.ASSIS_TOKEN;
const body=process.env.ASSIS_BODY;
const useHeader=process.env.ASSIS_HEADER==='1';
const headers={'content-type':'application/json'};
if(useHeader)headers['x-assis-internal-token']=token;
fetch('http://127.0.0.1:5678'+path,{method:'POST',headers,body})
.then(async r=>{const t=await r.text(); console.log(r.status+'|'+t);})
.catch(e=>{console.error(e);process.exit(2)});
'@
  $out=& docker exec --env "ASSIS_PATH=$Path" --env "ASSIS_TOKEN=$Token" --env "ASSIS_BODY=$Body" --env "ASSIS_HEADER=$([int]$HeaderToken)" $n8n node -e $js 2>&1
  return (($out|Where-Object{$_})-join "`n").Trim()
}

if(-not(Test-Path .env)){throw '.env não encontrado.'}
$token=Read-EnvValue 'INTERNAL_AGENT_TOKEN'
if([string]::IsNullOrWhiteSpace($token)){throw 'INTERNAL_AGENT_TOKEN ausente.'}

Write-Host '=== Diagnóstico preciso de autenticação do Outbound Text ==='
$verifyBody=@{token=$token;secret_name='core-internal-agent'}|ConvertTo-Json -Compress
$verify=Invoke-N8n '/webhook/assis/internal/auth/verify' $token $verifyBody $false
Write-Host "Verifier direto: $verify"

$probe=@{
  organization_id='00000000-0000-0000-0000-000000000000'
  conversation_id='00000000-0000-0000-0000-000000000000'
  idempotency_key=('auth-probe-'+[guid]::NewGuid().ToString('N'))
  to='5511999999999'
  text='auth probe'
  channel='whatsapp'
}|ConvertTo-Json -Compress
$outbound=Invoke-N8n '/webhook/assis/internal/message/send-text' $token $probe $true
Write-Host "Outbound probe: $outbound"

$n8n=Get-ComposeContainer 'n8n'
Write-Host '--- logs recentes relacionados a unauthorized outbound text call ---'
$logs=& docker logs --tail 300 $n8n 2>&1 | Select-String -Pattern 'unauthorized outbound text call|Starter 06 Outbound Text|Verify Internal Auth|Enforce Internal Auth|Error in workflow'
if($logs){$logs|ForEach-Object{Write-Host $_.Line}}else{Write-Host 'INFO: nenhum log correspondente encontrado.'}
Write-Host 'INFO: nenhum token foi impresso intencionalmente.'
