# Assis SmartFlow

Framework modular de **Secretária/Atendente** baseado em n8n para implantações autônomas. Não é SaaS.

A identidade padrão é **Maya**. Ela se apresenta como secretária/atendente da organização configurada, em tom cordial, paciente e natural, e nunca se apresenta como IA ou assistente virtual.

## Camadas

- `core/`: n8n, PostgreSQL/pgvector, Redis, Qdrant, proxy, migrações, segurança e contratos.
- `starter/`: atendimento por texto, agenda, contexto, RAG, memória, handoff e Kanban.
- `professional/`: voz, recuperação de leads, lembretes, documentos e pagamentos.
- `enterprise/`: RBAC, aprovações, retenção, DLQ, auditoria e operação com worker.
- `library/`: workflows reutilizáveis e contratos canônicos.
- `mcp/`: catálogo MCP versionado.
- `docs/`: arquitetura, implantação, segurança, LGPD, runbooks e homologação.
- `tests/`: validações estáticas, contratos e cenários de conversação.

## Primeira execução

1. Copie `.env.example` para `.env` e preencha apenas os segredos necessários.
2. Execute `python scripts/validate.py`.
3. Execute `python -m pytest -q`.
4. Suba o Core: `docker compose --env-file .env -f core/docker-compose.yml up -d`.
5. Aplique `core/db/migrations/001_core.sql`, `002_enterprise.sql` e `003_policies.sql`.
6. Importe somente o pack desejado no n8n e configure credenciais pelo credential store do n8n.

Consulte `docs/implementation/ROADMAP.md` e `docs/homologation/FINAL-HOMOLOGATION.md` antes de promover para produção.
