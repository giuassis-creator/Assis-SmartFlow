# Google Calendar OAuth no Assis SmartFlow

O Core Runtime permanece independente de provedores externos. Os adapters de agenda só são publicados depois que a credencial OAuth do Google Calendar estiver criada e conectada no n8n.

## Credencial OAuth

Use uma credencial do tipo **Google Calendar OAuth2 API**. O nome preferido é:

`Assis Google Calendar`

Se houver exatamente uma credencial do tipo `googleCalendarOAuth2Api`, o configurador também consegue detectá-la automaticamente mesmo com outro nome, como o nome padrão criado pelo n8n.

Nunca salve Client Secret, refresh token ou access token nos JSON dos workflows ou no Git.

Para bootstrap local do OAuth, o projeto inclui `core/docker-compose.oauth-local.yml`, que usa o callback:

`http://localhost:5678/rest/oauth2-credential/callback`

Esse override é somente para conectar/reconectar OAuth. Depois da conexão, `deploy-google-calendar.ps1` recria apenas o n8n na configuração normal HTTPS via Caddy.

## Workflows

- `Starter 04 Calendar Availability` — leitura de disponibilidade.
- `Starter 05 Calendar Book` — criação de evento.
- `Starter 08 Calendar Reschedule` — alteração de horário.
- `Starter 09 Calendar Cancel` — remoção de evento.

Os quatro workflows usam a credencial simbólica `ASSIS_GOOGLE_CALENDAR`. Os três writes também usam `ASSIS_POSTGRES` para o gate persistente de idempotência.

## Segurança

Os adapters não possuem mais endpoints `/webhook/mcp/calendar/*`. Todos os webhooks são internos:

- `POST /webhook/assis/internal/calendar/availability`
- `POST /webhook/assis/internal/calendar/book`
- `POST /webhook/assis/internal/calendar/reschedule`
- `POST /webhook/assis/internal/calendar/cancel`

O Caddy bloqueia `/webhook/assis/internal/*` com HTTP 404, portanto esses endpoints não são expostos pela superfície pública `https://assis.localhost`.

Além do bloqueio de proxy, cada adapter exige `x-assis-internal-token` e valida o token pelo workflow central `Internal Auth Verify` antes de acessar o Google Calendar.

O caminho normal é:

`Maya/Calendar Agent -> Internal Tool Policy Gateway -> internal Calendar adapter -> Google Calendar`

Criar, reagendar e cancelar também exigem `confirmed=true` e `idempotency_key`.

## Idempotência persistente

A migration `005_tool_idempotency.sql` cria `tool_idempotency` com chave primária composta por:

`organization_id + operation + idempotency_key`

Antes de qualquer write no Google, o workflow tenta reservar essa chave com `INSERT ... ON CONFLICT DO NOTHING`. Uma chave repetida é rejeitada antes do side effect no provider. Após sucesso, a resposta normalizada é armazenada e o registro passa para `completed`.

Esse comportamento implementa proteção persistente **at-most-once**. Se houver falha depois da reserva e antes da conclusão, a chave permanece reservada deliberadamente para evitar repetir um side effect cujo resultado no provider possa ser incerto.

## Implantação automática

Depois que a credencial OAuth estiver conectada, use:

```powershell
cd D:\Assis-SmartFlow
git pull origin main
.\scripts\windows\deploy-google-calendar.ps1
```

O script executa, em ordem:

1. reimportação dos workflows atuais;
2. migration `005_tool_idempotency.sql`;
3. binding automático das credenciais Google Calendar e PostgreSQL;
4. publicação dos quatro adapters e do `Internal Tool Policy Gateway` atualizado;
5. restauração do n8n para HTTPS normal via Caddy, removendo a necessidade da porta local 5678;
6. verificação de registro dos quatro webhooks internos;
7. teste de que o Caddy devolve 404 para o endpoint interno;
8. `pytest` específico dos contratos Calendar;
9. smoke runtime real no Google Calendar.

O smoke cria um único evento temporário chamado `[Assis SmartFlow QA] temporary runtime smoke`, testa duplicidade, reagenda e cancela o evento. Se ocorrer erro depois da criação, tenta executar cleanup automático.

Para usar uma agenda diferente da `primary`:

```powershell
.\scripts\windows\deploy-google-calendar.ps1 -CalendarId "<calendar-id>"
```

Para executar implantação e validação estática sem writes reais:

```powershell
.\scripts\windows\deploy-google-calendar.ps1 -SkipRuntimeSmoke
```

## Contratos funcionais

`calendar.availability` exige `organization_id`, `time_min` e `time_max`; `calendar_id` é opcional e usa `primary` por padrão.

`calendar.book` exige `organization_id`, `start`, `end`, `idempotency_key` e `confirmed=true`.

`calendar.reschedule` exige `organization_id`, `event_id`, novo `start`, novo `end`, `idempotency_key` e `confirmed=true`.

`calendar.cancel` exige `organization_id`, `event_id`, `idempotency_key` e `confirmed=true`.

## Homologação

Validação estática: `tests/test_calendar_adapters.py`.

Homologação runtime: `scripts/smoke_calendar_runtime.py` através do container `qa`.

Só marque Google Calendar como runtime-homologado depois que `deploy-google-calendar.ps1` terminar com o `PASS` final.
