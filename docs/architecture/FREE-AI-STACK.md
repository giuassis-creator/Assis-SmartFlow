# Stack de IA gratuita/local

## Padrão

- **LLM:** Ollama `0.33.3` com `qwen3:4b-instruct`.
- **Embeddings:** Ollama com `nomic-embed-text`.
- **STT:** `faster-whisper==1.2.1`, modelo `small`, CPU/int8 por padrão.
- **TTS:** KokoroTTS `v0.2`, executado localmente.
- **Fallback pago:** desativado (`AI_ALLOW_PAID_FALLBACK=false`).

O desenho mantém `n8n -> contrato MCP -> provider`, portanto os modelos podem ser trocados sem alterar a regra de negócio.

## Perfis de hardware

- 8 GB RAM: Qwen3 4B quantizado + Whisper small em CPU; evite concorrência alta.
- 16 GB RAM: configuração recomendada para Starter/Professional leve.
- GPU NVIDIA: habilite aceleração do Ollama/STT/TTS via override específico do host; não é requisito funcional.

## Bootstrap

`docker compose --env-file .env -f core/docker-compose.yml up -d --build`

O serviço `ollama-init` baixa o modelo de chat e o modelo de embeddings na primeira subida. Depois os pesos ficam persistidos em `ollama_data`.

## Política de custo

Nenhum fluxo do Core/Starter deve exigir chave de API de LLM. APIs comerciais só podem ser adicionadas como fallback explícito e continuam desativadas por padrão.
