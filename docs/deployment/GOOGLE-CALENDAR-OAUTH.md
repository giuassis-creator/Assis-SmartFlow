# Google Calendar OAuth no Assis SmartFlow

O Core Runtime permanece independente de provedores externos. Os quatro adapters de agenda só devem ser publicados depois que a credencial OAuth do Google Calendar estiver criada e validada no n8n.

## Credencial obrigatória

No n8n, crie uma credencial do tipo **Google Calendar OAuth2 API** com o nome exato:

`Assis Google Calendar`

Conclua o login/consentimento na conta Google que possui acesso à agenda usada pelo atendimento. O tipo interno da credencial é `googleCalendarOAuth2Api`.

## Workflows preparados

- `Starter 04 Calendar Availability` — leitura de disponibilidade.
- `Starter 05 Calendar Book` — criação de evento; exige `confirmed=true` e `idempotency_key`.
- `Starter 08 Calendar Reschedule` — alteração de horário; exige `confirmed=true`, `idempotency_key` e `event_id`.
- `Starter 09 Calendar Cancel` — remoção de evento; exige `confirmed=true`, `idempotency_key` e `event_id`.

Os arquivos no repositório usam a referência simbólica `ASSIS_GOOGLE_CALENDAR`. Nunca salve client secret, refresh token ou access token nos JSON dos workflows ou no Git.

## Sincronizar e publicar

Após criar e testar a credencial no n8n:

```powershell
cd D:\Assis-SmartFlow
.\scripts\windows\import-workflows.ps1 -Force
.\scripts\windows\configure-google-calendar.ps1
```

O segundo script:

1. procura exatamente uma credencial `Assis Google Calendar` do tipo `googleCalendarOAuth2Api`;
2. substitui a referência simbólica pelo ID real da credencial dentro do banco do n8n;
3. publica somente os quatro workflows de Calendar;
4. reinicia apenas o n8n para registrar os webhooks.

Se a credencial não existir, o script interrompe sem publicar nenhum adapter.

## Contratos HTTP

Os endpoints são:

- `POST /webhook/mcp/calendar/availability`
- `POST /webhook/mcp/calendar/book`
- `POST /webhook/mcp/calendar/reschedule`
- `POST /webhook/mcp/calendar/cancel`

Use `calendar_id` para selecionar a agenda; quando omitido, o adapter usa `primary`.

### Disponibilidade

Entrada mínima:

```json
{
  "organization_id": "<uuid>",
  "calendar_id": "primary",
  "time_min": "2026-09-08T09:00:00-03:00",
  "time_max": "2026-09-08T18:00:00-03:00"
}
```

### Agendar

Entrada mínima:

```json
{
  "organization_id": "<uuid>",
  "calendar_id": "primary",
  "start": "2026-09-08T14:00:00-03:00",
  "end": "2026-09-08T14:30:00-03:00",
  "summary": "Consulta",
  "idempotency_key": "<chave-unica>",
  "confirmed": true
}
```

### Reagendar

Exige `event_id`, novo `start`, novo `end`, `idempotency_key` e `confirmed=true`.

### Cancelar

Exige `event_id`, `idempotency_key` e `confirmed=true`.

## Segurança

A leitura de disponibilidade não requer confirmação humana. Criar, reagendar e cancelar são efeitos colaterais e continuam bloqueados sem confirmação explícita. O Policy Gateway deve permanecer como caminho normal de execução dessas ferramentas.

## Homologação

A presença dos nodes Google Calendar e dos gates de confirmação é coberta por `tests/test_calendar_adapters.py`. A homologação runtime real só é considerada concluída depois de conectar uma credencial OAuth válida e testar operações contra uma agenda de homologação.
