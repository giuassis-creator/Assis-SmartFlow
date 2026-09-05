# Docker Desktop no Windows

O ambiente local recomendado para desenvolvimento/homologação usa Docker Desktop com backend WSL2.

## Subida

No PowerShell, em `D:\Assis-SmartFlow`:

```powershell
Copy-Item .env.example .env
# edite .env e troque todos os CHANGE_ME
.\scripts\windows\bootstrap-docker-desktop.ps1
```

O override `core/docker-compose.desktop.yml` expõe portas somente para diagnóstico local. Em produção, use apenas `core/docker-compose.yml`, mantendo PostgreSQL/Redis/Qdrant/IA na rede interna.

## Serviços locais

- n8n: `https://assis.localhost` via Caddy; diagnóstico `http://localhost:5678`.
- Ollama: `localhost:11434`.
- Qdrant: `localhost:6333`.
- faster-whisper: `localhost:8000`.
- KokoroTTS: `localhost:7860`.

## GPU

A configuração padrão funciona em CPU. Para NVIDIA, habilite suporte GPU no Docker Desktop/WSL2 e use um override específico para reservar GPU; CPU permanece o fallback portátil.

## Segurança

As portas de diagnóstico do override Desktop não devem ser abertas na Internet. O token `INTERNAL_AGENT_TOKEN` protege chamadas internas entre o orquestrador e os agentes, mas o isolamento de rede continua obrigatório em produção.
