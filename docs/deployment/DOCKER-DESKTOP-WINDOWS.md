# Docker Desktop no Windows

Dentro de `D:\Assis-SmartFlow`:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\bootstrap-docker-desktop.ps1
```

O bootstrap valida Docker/Compose, cria `.env` com segredos aleatórios, executa QA em container, sobe PostgreSQL/pgvector, Redis, Qdrant, n8n, Ollama, faster-whisper, Kokoro e Caddy, cria `assis_knowledge`, importa workflows e executa smoke test da IA local.

Os workflows permanecem não publicados/ativados após importação. Configure credenciais externas antes de ativar os fluxos que dependem de Google Calendar, Evolution/Chatwoot, voz de telefonia ou pagamentos.

Diagnóstico local: n8n `http://localhost:5678`, Ollama `http://localhost:11434`, Qdrant `http://localhost:6333`, STT `http://localhost:8000`, TTS `http://localhost:7860`.
