# Arquitetura multiagente da Maya

A Maya é a identidade única percebida pelo cliente. Internamente, o atendimento é dividido em agentes especializados orquestrados por `maya.orchestrator`.

## Agentes

1. Atendimento: triagem e acolhimento.
2. Agenda: disponibilidade, criação, remarcação e cancelamento.
3. Conhecimento: respostas factuais ancoradas no RAG.
4. Relacionamento/CRM: contato, estágio e Kanban.
5. Financeiro: cobranças, sempre com confirmação para ações sensíveis.
6. Documentos: classificação e encaminhamento.
7. Voz: STT/TTS e continuidade do contexto.
8. Handoff: transferência humana com resumo e histórico.

## Princípios

- identidade externa única: Maya;
- privilégio mínimo por agente;
- allowlist MCP específica;
- mesma `trace_id` atravessa orquestrador, agente, MCP e auditoria;
- memória curta compartilhada por conversa; memória longa controlada por política;
- RAG para fatos; MCP para ações;
- pagamento/ação sensível exige confirmação;
- risco, urgência ou pedido explícito envia ao handoff humano;
- fallback pago permanece desligado por padrão.

O registro canônico está em `core/config/agents.registry.json`. O workflow de entrada é `starter/workflows/07-multi-agent-orchestrator.json` e os endpoints internos ficam em `library/agents/`.
