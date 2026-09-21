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
- [x] Homologação funcional E2E WAHA com saída simulada, contexto/RAG, autenticação e idempotência; validação mais recente na AWS com modelos locais reais: 148 testes aprovados e 1 ignorado (2026-09-18).
- [ ] Homologação E2E real WAHA: **BLOCKED por capacidade local do planner**. A tentativa autorizada de 2026-09-18 comprovou a nova identificação da entrada, mas o `/api/chat` excedeu 240 s e nenhuma resposta outbound foi persistida. Por decisão do responsável, não haverá repetição automática sem nova autorização. A voz foi posteriormente implantada e homologada; o gateway de pagamento permanece adiado.
- [x] Teste de carga simulada e restore drill em infraestrutura isolada: restore fiel aprovado; 18 requisições de carga HTTP 200, zero erros, provider simulado sem entrega e unicidade preservada em AWS EC2 dedicada (2026-09-16).
- [x] Cache de modelos E2E independente, harness fail-closed, cleanup protegido e evidência estruturada validados. A validação atual não executou E2E real nem enviou resposta automática real.
- [x] Implantação controlada atualizada para oito workflows WAHA/Maya, com credenciais vinculadas, publicação, 38 contratos aprovados e sessão WAHA `WORKING`; nenhum envio real na validação (2026-09-18).
- [x] Timeouts internos de 240 s no planner/resposta final e 540 s no despacho Maya validados no E2E isolado e implantados (commit `68906e29203c777554ac133a2d447ff095de46a6`).
- [x] Homologação runtime do Google Calendar aprovada: disponibilidade, confirmação, idempotência, criação, reagendamento e cancelamento do evento temporário (11 testes estáticos, 2026-09-19).
- [x] Voz local implantada: quatro workflows de voz publicados; STT faster-whisper e TTS Kokoro ativos. Smoke sintético local aprovado, gerando 127.244 bytes e transcrevendo em português, sem áudio externo (2026-09-19).

- [x] Operação local endurecida: monitor horário com alerta no Log de Aplicativos do Windows, backup PostgreSQL diário às 03:00, espelho SHA-256 em `C:\Assis-SmartFlow-Backups`, retenção de 30 dias e teste mensal de restauração no dia 1 às 04:00; as três tarefas foram executadas pelo Agendador com resultado 0 (2026-09-21).
- [x] Recuperação de desastre documentada e validada: restore isolado com 151 tabelas públicas e 48 workflows, remoção do banco temporário, configuração `.env` protegida por AES-256-GCM e runbook Windows versionado. A sessão WAHA será reconectada por QR Code e não será armazenada em backup (2026-09-21).
