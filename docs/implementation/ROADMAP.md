# Roadmap executado

- [x] Core com imagens versionadas, proxy TLS-ready, redes separadas e healthchecks.
- [x] PostgreSQL/pgvector + esquema transacional, memória, RAG, handoff, Kanban, auditoria, RBAC, approvals e DLQ.
- [x] Contrato de envelope canônico e idempotência.
- [x] Memória curta/longa e política de categorias.
- [x] RAG com ingestão/chunking e contrato de busca; embeddings/provider ficam configuráveis no n8n.
- [x] Kanban e transições permitidas.
- [x] MCP catalog versionado para agenda, CRM, knowledge, handoff, Kanban, pagamentos e voz.
- [x] Adaptadores separados para Evolution API e Chatwoot.
- [x] Secretária Maya com política central, handoff e proteção contra invenção de fatos/ferramentas.
- [x] Professional: voz, lembretes, lead recovery, documentos, pagamentos, Chatwoot handoff.
- [x] Enterprise: queue mode, RBAC, approval gate, retenção e DLQ retry.
- [x] Backup/restore, CI, testes de contrato, segurança e golden conversations.
- [ ] Homologação E2E com credenciais reais de staging (Google Calendar, Evolution/Chatwoot, LLM/embeddings, voz e Asaas).
- [ ] Teste de carga e restore drill em infraestrutura alvo.
