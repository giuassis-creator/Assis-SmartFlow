# Homologação final

Status: **PASS estrutural/local** para JSON, manifests, contratos, política de identidade, idempotência, segurança estática e golden scenarios. A homologação E2E permanece condicionada a serviços reais de staging e credenciais.

Pendências E2E: mensagem real Evolution/Chatwoot -> persistência -> RAG -> resposta; agenda real; handoff real; chamada de voz; pagamento sandbox; retry/DLQ; carga; backup e restore.

## WAHA outbound — sincronização da correção homologada (2026-09-14)

Status: **PASS — correção implantada e verificada sem novo envio real**.

- Alvo único: `starter/workflows/06-outbound-text.json`, nó PostgreSQL `Persist Outbound Message`.
- Duas substituições autorizadas em Query Parameters: `raw:$json.raw||{}` por `raw:$json.raw ?? null` e `$json.provider_message_id||null` por `$json.provider_message_id ?? null`.
- Os nós e conexões do fonte corrigido correspondem ao workflow editável e ao snapshot publicado no n8n, normalizando somente os IDs das credenciais PostgreSQL. Os nós publicados são idênticos aos da versão homologada anterior. O fonte mantém `active=false` conforme a convenção de importação; o workflow implantado está ativo, com `versionId=activeVersionId`.
- A importação omitiu o antigo campo explícito `settings.binaryMode=separate`, ausente no fonte. Equivalência confirmada no código instalado do n8n 2.37.7: os helpers binários usam `BINARY_MODE_SEPARATE` como padrão, e a conversão/proxy só muda o comportamento para `BINARY_MODE_COMBINED`. As demais configurações foram preservadas.
- Inspeção estrutural: 48 workflows íntegros; 21 campos Query Parameters sem outros candidatos a encerramento antecipado por `}}` após a correção.
- QA pelo container existente: validação estática e suíte completa aprovadas, com 91 testes. Todos os 70 arquivos JSON versionados são válidos; o diff do workflow contém somente as duas substituições autorizadas.
- Falso positivo corrigido em `scripts/validate.py`: somente atribuições completas de variáveis de credenciais conhecidas, no template raiz `.env.example`, aceitam `CHANGE_ME` ou seu valor explícito reconhecido. A referência PostgreSQL e os campos vazios existentes continuam permitidos. Nenhum arquivo é excluído da inspeção; os demais padrões de detecção permanecem ativos.
- Regressão: 30 casos adicionais cobrem placeholders exatos, valores de aparência real nas 13 variáveis de credenciais, prefixos/sufixos suspeitos, contexto incorreto e segredos adicionais no mesmo arquivo. Valores rejeitados não são reproduzidos no diagnóstico. Nenhum placeholder foi substituído por credencial real; a alteração prévia de `.env.example` foi preservada e excluída do commit desta correção.
- Implantação pelos procedimentos existentes: `import-workflows.ps1 -Force -Only starter/workflows/06-outbound-text.json`, `bind-postgres-workflow-credentials.ps1`, `n8n publish:workflow` somente para o alvo e `docker compose restart n8n`. A pré-verificação confirmou que o vínculo global de credenciais não exigia alterações em outros workflows.
- Pós-implantação somente com GET/SELECT: saúde do n8n e provider-gateway com HTTP 200, rota outbound POST registrada uma única vez, sessão WAHA `WORKING` com identidade preservada e segredos WAHA ausentes do processo n8n. Comparações anteriores/posteriores confirmaram credenciais, registros das sete tabelas de negócio/roteamento/autenticação verificadas, demais workflows, mounts dos volumes e arquivos de ambiente inalterados. Os containers n8n, PostgreSQL, WAHA, provider-gateway e Redis mantiveram seus IDs; somente n8n foi reiniciado.
- A homologação outbound real anterior foi informada como aprovada pelo responsável. Nenhum envio real, chamada ao endpoint outbound ou recriação de sessão WAHA foi realizado nesta implantação. Evidências privadas anteriores/posteriores ficam em `.local/outbound-fix/`, fora do versionamento.
