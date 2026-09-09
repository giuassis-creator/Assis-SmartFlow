$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $root

Write-Host '=== Assis SmartFlow - reparo de autenticação interna runtime ==='

& "$PSScriptRoot\configure-internal-auth.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

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
$token = Read-EnvValue 'INTERNAL_AGENT_TOKEN'
if ([string]::IsNullOrWhiteSpace($token)) { throw 'INTERNAL_AGENT_TOKEN ausente.' }
$n8n = Get-ComposeContainer 'n8n'
$js = @'
const token=process.env.ASSIS_TOKEN;
fetch('http://127.0.0.1:5678/webhook/assis/internal/auth/verify',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({token,secret_name:'core-internal-agent'})})
.then(async r=>{const t=await r.text(); console.log(r.status+'|'+t); if(r.status!==200)process.exit(3); try{const j=JSON.parse(t); if(j.valid!==true)process.exit(4);}catch{process.exit(5);}})
.catch(e=>{console.error(e);process.exit(2)});
'@
$out = & docker exec --env "ASSIS_TOKEN=$token" $n8n node -e $js 2>&1
if ($LASTEXITCODE -ne 0) { throw "Verifier interno não aceitou o token configurado:`n$($out -join "`n")" }
Write-Host 'PASS: verifier interno aceita o INTERNAL_AGENT_TOKEN atual.'
Write-Host 'NEXT: execute novamente o smoke outbound WAHA autorizado.'
