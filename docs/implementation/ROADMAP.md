# Roadmap executado

- [x] Core com imagens versionadas, proxy TLS-ready, redes separadas e healthchecks.
- [x] PostgreSQL/pgvector + esquema transacional, memória, RAG, handoff, Kanban, auditoria, RBAC, approvals e DLQ.
- [x] Contrato de envelope canônico e idempotência.
- [x] Memória curta/longa e política de categorias.
- [x] RAG com ingestão/chunking e contrato de busca; embeddings/provider ficam configuráveis no n8n.
- [x] Kanban e transições permitidas.
- [x] MCP catalog versionado para agenda, CRM, knowledge, handoff, Kanban, pagamentos e voz.
- [x] Adaptadores de canal separados; WAHA é o canal da fase atual. Evolution/Chatwoot ficam reservados para fases futuras.
- [x] Secretária Maya com política central, handoff e proteção contra invenção de fatos/ferramentas.
- [x] Professional: voz, lembretes, lead recovery, documentos, pagamentos, Chatwoot handoff.
- [x] Enterprise: queue mode, RBAC, approval gate, retenção e DLQ retry.
- [x] Backup/restore, CI, testes de contrato, segurança e golden conversations.
- [x] Homologação funcional E2E WAHA com saída simulada, contexto/RAG, autenticação e idempotência; harness descarrega `nomic-embed-text` antes do planner (105 testes, 2026-09-15).
- [ ] Homologação E2E real WAHA, pendente de autorização específica para mensagens e resposta automática; demais provedores de staging (Google Calendar, voz e Asaas) continuam pendentes.
- [ ] Teste de carga e restore drill em infraestrutura alvo.
- [x] Restore drill isolado aprovado; harness de carga simulado implementado. Baseline de carga permanece **BLOCKED** pela capacidade local do planner Ollama (2026-09-16). Cache de modelos E2E independente validado; E2E real e respostas automáticas reais continuam não autorizados.
- [x] ImplantaÃ§Ã£o controlada dos cinco workflows WAHA aprovados, com credenciais vinculadas, publicaÃ§Ã£o e pÃ³s-check simulado (2026-09-15).
