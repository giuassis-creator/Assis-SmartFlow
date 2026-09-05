# Arquitetura

Fluxo canônico: `Canal -> Adaptador -> Envelope canônico -> Persistência/Idempotência -> Contexto/Memória/RAG -> Maya -> MCP -> Adaptador de saída`.

Os adaptadores de Evolution API, Chatwoot e voz não contêm lógica de negócio. O Core não conhece payload proprietário do canal. Todo efeito colateral passa por contrato MCP e ferramentas de escrita recebem `idempotency_key` quando aplicável.

PostgreSQL é a fonte transacional; Redis atende fila/coordenação; Qdrant é o vetor local. Handoff grava motivo, prioridade, resumo e até 20 mensagens recentes antes de acionar o canal humano.
