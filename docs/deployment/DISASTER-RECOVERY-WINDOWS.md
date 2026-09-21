# Recuperação completa — Windows e Docker Desktop

Este procedimento reconstrói o Assis SmartFlow após perda do ambiente local. Ele usa o código no GitHub, um backup PostgreSQL smartflow-*.dump, a configuração criptografada assis-config-*.ascfg e uma nova autenticação WAHA por QR Code.

A sessão WAHA não é copiada. Redis, modelos Ollama e índices Qdrant são reconstruídos.

## Pré-requisitos

- Windows com PowerShell 7, Git e Docker Desktop;
- acesso ao repositório;
- backup PostgreSQL íntegro;
- arquivo de configuração criptografado;
- senha guardada separadamente.

## 1. Recuperar o código

~~~powershell
git clone https://github.com/giuassis-creator/Assis-SmartFlow.git D:\Assis-SmartFlow
cd D:\Assis-SmartFlow
git pull --ff-only origin main
git status --short
~~~

O último comando deve estar vazio.

## 2. Restaurar a configuração

~~~powershell
$archive = 'C:\Assis-SmartFlow-Backups\config\assis-config-AAAAmmdd-HHmmss.ascfg'
.\scripts\windows\protect-smartflow-config.ps1 -Mode Verify -ArchivePath $archive
~~~

Em uma instalação nova:

~~~powershell
if (Test-Path -LiteralPath '.env') { throw 'O .env já existe. Preserve-o antes de continuar.' }
.\scripts\windows\protect-smartflow-config.ps1 -Mode Restore -ArchivePath $archive -DestinationPath 'D:\Assis-SmartFlow\.env'
~~~

Nunca coloque a senha em linha de comando, arquivo, Git ou tarefa agendada.

## 3. Iniciar somente o PostgreSQL

~~~powershell
$compose = @('--env-file', '.env', '-f', 'core/docker-compose.yml', '-f', 'core/docker-compose.desktop.yml')
docker compose @compose config --quiet
docker compose @compose up -d postgres
docker compose @compose ps postgres
~~~

Aguarde o PostgreSQL ficar healthy.

## 4. Restaurar o banco

> Atenção: esta seção substitui o banco configurado no .env. Execute somente em ambiente novo ou após confirmar uma recuperação de desastre.

Selecione o backup e resolva o alvo:

~~~powershell
$backup = Get-Item 'C:\Assis-SmartFlow-Backups\smartflow-AAAAmmdd-HHmmss.dump'
$postgres = (docker compose @compose ps -q postgres).Trim()
$pgUser = (docker exec $postgres printenv POSTGRES_USER).Trim()
$pgDb = (docker exec $postgres printenv POSTGRES_DB).Trim()
if (-not $postgres -or -not $pgUser -or -not $pgDb) { throw 'Alvo PostgreSQL não foi resolvido.' }
~~~

Copie, recrie e restaure:

~~~powershell
docker cp $backup.FullName "$($postgres):/tmp/assis-recovery.dump"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao copiar o backup.' }

docker exec $postgres psql --username $pgUser --dbname postgres --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$pgDb' AND pid <> pg_backend_pid();"
if ($LASTEXITCODE -ne 0) { throw 'Falha ao encerrar conexões do banco alvo.' }

docker exec $postgres dropdb --username $pgUser --if-exists $pgDb
if ($LASTEXITCODE -ne 0) { throw 'Falha ao remover o banco alvo.' }

docker exec $postgres createdb --username $pgUser --owner $pgUser $pgDb
if ($LASTEXITCODE -ne 0) { throw 'Falha ao recriar o banco alvo.' }

docker exec $postgres pg_restore --username $pgUser --dbname $pgDb --no-owner --no-privileges --exit-on-error /tmp/assis-recovery.dump
if ($LASTEXITCODE -ne 0) { throw 'Falha ao restaurar o banco.' }

docker exec $postgres rm -f /tmp/assis-recovery.dump
~~~

Valide:

~~~powershell
docker exec $postgres psql --username $pgUser --dbname $pgDb --tuples-only --no-align --command 'SELECT count(*) FROM workflow_entity;'
~~~

O ambiente homologado possuía 48 workflows. Um valor diferente exige investigação antes de iniciar o n8n.

## 5. Iniciar os serviços

~~~powershell
docker compose @compose up -d
docker compose @compose ps
~~~

Aguarde os serviços essenciais ficarem saudáveis.

## 6. Reconectar o WhatsApp

A sessão WAHA não é restaurada por backup:

~~~powershell
.\scripts\windows\deploy-waha-provider.ps1
~~~

Se a sessão não estiver WORKING, abra a interface WAHA em loopback e leia um novo QR Code. Não exponha a porta WAHA publicamente.

## 7. Reconstruir modelos e índices

Confira os modelos:

~~~powershell
docker exec assis-smartflow-ollama-1 ollama list
~~~

Se o volume Qdrant tiver sido perdido, reingira os documentos autorizados. O RAG não está recuperado apenas porque o container Qdrant iniciou.

## 8. Verificações finais

~~~powershell
.\scripts\windows\monitor-smartflow.ps1
curl.exe -k -s -o NUL -w "n8n HTTPS: %{http_code}\n" https://assis.localhost/
curl.exe -k -s -o NUL -w "rota interna: %{http_code}\n" https://assis.localhost/webhook/assis/internal/auth/verify
docker exec assis-smartflow-provider-gateway-1 python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/healthz').read().decode())"
~~~

Resultados esperados:

- n8n HTTPS retorna 200;
- rota interna pública retorna 404;
- provider-gateway retorna ok=true;
- WAHA default fica WORKING;
- 48 workflows estão presentes;
- Google Calendar é reconectado se o token for revogado;
- RAG é reingerido se o volume Qdrant for perdido.

## 9. Recriar tarefas agendadas

Abra o PowerShell 7 como administrador e execute:

~~~powershell
.\scripts\windows\install-operational-tasks.ps1 -MirrorPath 'C:\Assis-SmartFlow-Backups' -BackupTime '03:00' -RestoreTime '04:00'
~~~

O instalador é idempotente e recria:

- monitor horário;
- backup diário às 03:00 com espelho;
- teste mensal de restauração no dia 1 às 04:00.

As tarefas usam o usuário conectado porque o Docker Desktop depende da sessão desse usuário. Valide cada tarefa com uma execução controlada; LastTaskResult deve ser igual a 0.

## Critério de conclusão

A recuperação termina somente quando o banco foi validado, o n8n responde por HTTPS, as rotas internas continuam bloqueadas externamente, os serviços essenciais estão saudáveis, o WAHA foi reconectado, as integrações necessárias foram verificadas e as tarefas operacionais foram reagendadas.
