# Arquitetura multiagente da Maya

A Maya é o único ponto de contato percebido pelo cliente. Internamente, o sistema usa `reception.agent`, `calendar.agent`, `knowledge.agent`, `crm.agent`, `finance.agent`, `document.agent`, `voice.agent` e `handoff.agent`, subordinados ao orquestrador `maya.orchestrator`.

Fluxo: `Canal -> Maya Orchestrator -> Agent Runtime -> plano JSON -> Tool Policy Gateway -> MCP/workflow autorizado -> resultado -> resposta final da Maya`.

O LLM não chama provedores diretamente. O gateway verifica token interno, allowlist por agente, implementação da ferramenta e confirmação explícita para agenda mutável e pagamentos. Chamadas bloqueadas viram `noop` estruturado.

O RAG usa embeddings locais do Ollama e Qdrant, sempre filtrando `organization_id`. Operações PostgreSQL usam parâmetros preparados e segredos ficam em `.env`/credential store do n8n.
