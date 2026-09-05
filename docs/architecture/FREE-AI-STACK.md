# Pilha de IA gratuita/local

A implantação padrão evita APIs pagas obrigatórias.

| Função | Padrão |
|---|---|
| LLM | Ollama + `qwen3:4b-instruct` |
| Embeddings | Ollama + `nomic-embed-text` (768 dimensões) |
| Vetores | Qdrant self-hosted |
| STT | faster-whisper 1.2.1 (`small`, CPU/int8) |
| TTS | KokoroTTS v0.2, voz pt-BR `pf_dora` |

`AI_ALLOW_PAID_FALLBACK=false` é o padrão. Provedores pagos podem ser adicionados futuramente como fallback explícito, sem alterar os contratos internos.
