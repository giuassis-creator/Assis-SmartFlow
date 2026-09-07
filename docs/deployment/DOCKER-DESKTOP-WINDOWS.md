# Docker Desktop no Windows

Dentro de `D:\Assis-SmartFlow`:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\bootstrap-docker-desktop.ps1
```

O bootstrap valida Docker/Compose, cria `.env` com segredos aleatórios, executa QA em container, sobe PostgreSQL/pgvector, Redis, Qdrant, n8n, Ollama, faster-whisper, Kokoro e Caddy, cria `assis_knowledge`, importa workflows e executa smoke test da IA local.

Os workflows permanecem não publicados/ativados após importação. Configure credenciais externas antes de ativar os fluxos que dependem de Google Calendar, Evolution/Chatwoot, voz de telefonia ou pagamentos.

## Acesso padrão endurecido

No modo padrão do Docker Desktop, apenas o Caddy publica portas no host. Use o editor n8n por:

```text
https://assis.localhost
```

Os serviços n8n, Ollama, Qdrant, STT e TTS permanecem acessíveis apenas pelas redes internas do Compose. O Caddy também bloqueia externamente os caminhos `/webhook/internal/*` e `/webhook/assis/internal/*`.

## Diagnóstico local temporário

Quando for necessário inspecionar serviços diretamente, acrescente o override de diagnóstico, que publica portas apenas em `127.0.0.1`:

```powershell
docker compose `
  --env-file .env `
  -f core/docker-compose.yml `
  -f core/docker-compose.desktop.yml `
  -f core/docker-compose.diagnostics.yml `
  up -d
```

Nesse modo temporário ficam disponíveis apenas no computador local:

- n8n: `http://127.0.0.1:5678`
- Ollama: `http://127.0.0.1:11434`
- Qdrant: `http://127.0.0.1:6333`
- STT: `http://127.0.0.1:8000`
- TTS: `http://127.0.0.1:7860`

Para retornar ao modo endurecido, execute novamente `scripts/windows/deploy-core-runtime.ps1`; a etapa de hardening recria apenas os containers necessários, sem remover volumes.
