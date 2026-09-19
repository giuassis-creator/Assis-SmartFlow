# Homologação final

Status: **PASS estrutural/local e no E2E isolado simulado** para JSON, manifests, contratos, política de identidade, idempotência, segurança estática, golden scenarios e cadeia completa com modelos locais reais. A implantação WAHA está concluída. A resposta automática real completa permanece não aprovada.

Pendências E2E: nova execução explicitamente autorizada do atendimento completo WAHA -> persistência -> RAG -> resposta real; agenda real; handoff real; chamada de voz; pagamento sandbox; retry/DLQ. Evolution/Chatwoot são adaptadores futuros, fora desta fase.

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

## WAHA — encadeamento E2E com saída simulada

Status: **PASS no E2E isolado simulado; implantação dos workflows concluída na atualização de 2026-09-18**. A resposta automática real completa continua não aprovada e exige nova autorização para repetição.

### Contratos e pontos de integração

| Fronteira | Contrato validado |
| --- | --- |
| WAHA → ingresso canônico | Sessão resolve exatamente uma organização habilitada. IDs organizacionais/conversa fornecidos pelo chamador não substituem o mapeamento. Simulação exige `simulation=true`, segredo WAHA válido e token interno adicional válido. |
| Persistência → Maya | `INSERT ... ON CONFLICT DO NOTHING RETURNING *` libera somente mensagens novas. `organization_id` e `conversation_id` vêm da linha persistida; o identificador externo do contato não é usado como UUID interno. |
| Maya/contexto/RAG | Texto, UUIDs e `trace_id` são encaminhados ao orquestrador existente. Contexto precisa corresponder à organização/conversa; RAG mantém filtro organizacional. Ferramentas propostas pelo modelo são suprimidas na simulação. |
| Resposta → Policy Gateway | Resposta não vazia, até 4096 caracteres, IDs/trace correspondentes e contexto carregado são exigidos. O despacho usa `reception.agent` e `message.send_text`, com chave `simulated-reply:<id da mensagem persistida>`. |
| Outbound → provider simulado | O outbound valida organização/conversa e reserva idempotência. `simulation=true` seleciona exclusivamente o endpoint interno fixo `assis/internal/message/simulate-provider`, autenticado e sem transporte de entrega. O nó `Persist Outbound Message` homologado permanece inalterado. |

Webhooks WAHA comuns continuam apenas na persistência. A simulação não promove o segredo WAHA a token interno, não depende de novos segredos de produção e não pode ser desativada por argumentos de ferramenta gerados pelo modelo. O provider retorna `provider=simulated`, `delivered=false` no payload e ID externo nulo. Falha simulada interrompe o fluxo sem registrar mensagem de saída bem-sucedida; a reserva permanece `claimed`, sem retry automático de resultado incerto. Replay da entrada não reexecuta a Maya.

### Verificações desta fase

- `python scripts/run_waha_simulated_e2e.py`: projeto Docker exclusivo `assis-smartflow-e2e-simulated`, rede interna sem saída externa, sem portas publicadas e sem provider real; n8n/PostgreSQL/Qdrant/Ollama reais. Somente o cache de modelos existente é montado para leitura. Banco e credenciais de teste são independentes.
- A suíte opt-in valida sucesso completo, códigos distintos da memória e do RAG na resposta, replay concorrente, isolamento entre organizações, autenticação inválida, falha segura do provider, bloqueio das ferramentas externas e preservação da expressão outbound homologada. A suíte normal não executa os cenários de runtime.
- Diagnóstico da execução anterior: entrada/persistência/contexto/RAG funcionaram; o HTTP 500 foi propagado do timeout no `Ollama Agent Planner`. O runner passou a aquecer o modelo antes das chamadas cronometradas, conforme o pré-requisito de `warm-local-ai.ps1`; os timeouts dos workflows foram preservados.
- A verificação seguinte manteve 97 testes estáticos aprovados, mas encontrou timeout ao adquirir conexão no pool interno do n8n durante a autenticação. O padrão instalado é de duas conexões; o ambiente isolado passou a usar dez para as chamadas encadeadas. Esse ajuste não altera o pool de produção nem os recursos globais do Docker; sua validação E2E permanece pendente.
- Evidências e diagnóstico ficam em `.local/e2e-simulated/`, fora do Git. A alteração preexistente em `.env.example` permanece fora do escopo.

### Retomada de 2026-09-15

- A execução anterior terminou com **103 passed, 1 failed** em 658,35 s; não foi aprovada. Antes de repetir, a consulta de processos e do projeto Docker confirmou que não havia teste em execução nem containers remanescentes. O log foi preservado em `.local/e2e-simulated/failure-before-replay-fix.log`.
- Causa do replay: no conflito idempotente, o nó PostgreSQL retornou apenas `{success: true}`. `Prepare Simulated Turn` tratava esse marcador como linha inválida e retornava HTTP 500. Agora o marcador exato retorna confirmação de duplicata pelo caminho sem Maya/provider; linhas incompletas continuam rejeitadas.
- A primeira repetição terminou com **103 passed, 1 failed** em 645,92 s: retornar zero itens ainda produzia HTTP 500 no webhook `lastNode` (`No item to return was found`). O log foi preservado em `.local/e2e-simulated/failure-before-replay-ack.log`.
- A correção final usa confirmação explícita `{ok:true,duplicate:true,simulation:false}` e roteia pelo sinal do item preparado. Verificação independente em JavaScript confirmou a confirmação fora da Maya, rejeição de linhas inválidas e preservação dos caminhos de mensagem nova e persistência comum. A segunda repetição completa terminou com **97 passed, 7 errors** em 268,80 s: a preparação compartilhada falhou no timeout de 180 s do `Ollama Agent Planner`, antes dos cenários de replay. O modelo já estava carregado; a causa da lentidão não foi estabelecida. Evidência preservada em `.local/e2e-simulated/failure-replay-ack-runtime.log`.
- A terceira repetição, sem mudar código, recursos ou timeouts, terminou com **97 passed, 7 errors** em 267,65 s e código de saída 1. A validação estrutural passou. Os dados de execução confirmaram novamente falha no `Ollama Agent Planner`; os sete cenários E2E falharam na preparação compartilhada. Log integral em `.local/e2e-simulated/run.log`.
- **Verificação final de conformidade: PASS.** Saída restrita ao ambiente simulado, rede interna sem gateway, n8n sem portas publicadas, cache de modelos somente leitura. Settings dos cinco workflows, nó completo `Persist Outbound Message` e hash de `.env.example` preservados. Nenhuma implantação em produção, commit, push ou mensagem real.
- **Verificação final de validade: FAIL no E2E.** Validação estrutural e 97 testes aprovados; execução direta do JavaScript e roteamento da correção aprovada. O replay corrigido ainda não foi validado na cadeia completa por causa do timeout recorrente na preparação. Não se declara homologação concluída. Ajustes de recursos globais, timeouts ou modelo não foram realizados; a causa da lentidão permanece sem comprovação.
- O harness E2E agora descarrega `nomic-embed-text` com `POST /api/embed` e `keep_alive:0` após os ingests e antes do planner. Exige HTTP 200 e confirma em `/api/ps` que somente o Qwen permanece residente; falhas produzem diagnóstico explícito e interrompem a fixture.
- Suíte completa após a alteração: **105 testes aprovados em 564,65 s**, incluindo o replay concorrente na cadeia completa, com uma única mensagem de entrada/saída persistida e nenhuma nova execução da Maya/provider no replay. O ambiente usou somente provider simulado, sem envio real.
- O descarregamento é exclusivo do harness/fixture E2E e não altera workflows de produção, recursos Docker, swap, modelo, contexto ou timeout. A correção permanente recomendada pertence apenas aos testes; nenhuma mudança equivalente foi aplicada ao runtime de produção.
- **Verificação final de conformidade: PASS.** A alteração fica em `tests/test_waha_simulated_e2e.py`; `.env.example` e os demais workflows fora do alvo permanecem preservados. **Verificação final de validade: PASS.** Validação estrutural, suíte completa e replay concorrente passaram; o provider simulado retornou `delivered=false` e nenhum transporte externo foi chamado.
### ImplantaÃ§Ã£o controlada de 2026-09-15

- Os cinco workflows WAHA aprovados foram importados, vinculados Ã  credencial PostgreSQL e publicados/ativos: Internal Auth Verify, 01 Canonical Ingress, Internal Tool Policy Gateway, Starter 06 Outbound Text e Starter 08 WAHA Inbound.
- PÃ³s-check exclusivamente simulado: replay concorrente/idempotÃªncia, autenticaÃ§Ã£o, isolamento organizacional e provider `delivered=false` permanecem aprovados pela suÃ­te E2E de 105 testes; nenhum transporte externo foi chamado.
- Runtime preservado: 48 workflows, 15 mensagens, 2 credenciais, volumes existentes, containers saudÃ¡veis e sessÃ£o WAHA `default` em `WORKING`. `WAHA_TEST_NUMBER` permaneceu vazio.

## Carga simulada e restore drill — aprovação (2026-09-16)

- **Restore drill: APPROVED.** PostgreSQL 16 foi restaurado em projeto e volume temporários, com 48 workflows, 15 mensagens, 2 credenciais e 3 extensões conferidas. Nenhum volume ou banco de produção foi usado.
- **Suíte E2E funcional: 120 passed, 7 skipped.** O bootstrap de carga adicional comprovou `Runtime.setup()` idempotente antes dos perfis.
- **Carga simulada: APPROVED.** Execução em AWS EC2 isolada (`m7i-flex.large`, 2 vCPU, 7,6 GiB de RAM e 4 GiB de swap), projeto `assis-smartflow-load-aws-full-1`, rede Docker interna, banco/credenciais efêmeros e cache Ollama exclusivo. O campo legado `baseline=local_hardware_only` no artefato identifica o baseline do harness; nesta aprovação o host foi a EC2 descrita acima.
- Foram concluídas **18 requisições, todas HTTP 200 e sem erros**: ingresso/persistência/idempotência (10; 830,310 s; 0,012 rps; p50 182,359 s; p95/p99 198,823 s), replay concorrente (4; 100,504 s; 0,040 rps; p50 1,615 s; p95/p99 100,502 s), RAG (2; 205,649 s; 0,010 rps; p50 101,993 s; p95/p99 103,656 s) e Maya/planner (2; 213,476 s; 0,009 rps; p50 104,490 s; p95/p99 108,985 s).
- Invariantes aprovadas: `provider=simulated`, `delivered=false` e `unique_messages=true`. Nenhum provider externo, envio real ou resposta automática real foi acionado.
- Durante uma inferência, a observação manual mostrou Ollama próximo de 100% de CPU e 4,772 GiB residentes; n8n usava aproximadamente 488 MiB. Não houve registro de OOM no kernel. CPU/memória/swap/I/O por requisição e filas PostgreSQL/Redis continuam explicitamente indisponíveis no JSON, sem valores estimados.
- O harness passou a aguardar o PostgreSQL definitivo por TCP, construir a imagem QA local, usar identidade determinística no replay do setup, gravar evidências fora do workspace somente leitura e omitir credenciais efêmeras do log de configuração.
- Cleanup final aprovado: zero containers, projetos Compose e redes temporárias; volume anônimo removido. Permaneceu somente `assis-smartflow-load-ollama-aws-20260916`, rotulado como cache E2E e separado de `assis-smartflow_ollama_data`.
- Evidências brutas permanecem em `.local/load-isolated/`, fora do Git. Produção, WAHA, dados, credenciais e volumes principais permaneceram intactos.
- E2E real WAHA e respostas automáticas reais permanecem **não autorizados**.

## Identificação E2E, timeouts e implantação — validação de 2026-09-18

Status: **APPROVED no E2E isolado simulado e na implantação sem novo envio real**. A resposta automática real completa permanece pendente.

- O runner real deixou de depender da igualdade byte a byte entre o corpo recebido e o marcador exibido. A entrada é selecionada somente após a abertura da janela e exige `payload.real_e2e=true`; o gateway continua responsável pelo gate temporário e pelo número autorizado.
- Os limites internos passaram a 240 s no `Ollama Agent Planner` e no `Ollama Final Response`, e a 540 s no despacho `Maya -> Agent Runtime`. Modelo `qwen3:4b-instruct`, `num_ctx=2048`, `num_predict=256`, prompts e timeout de 180 s da captura automática de memória foram preservados.
- Validação na AWS EC2 isolada: **148 passed, 1 skipped em 169,70 s**. A validação estrutural passou, os modelos locais reais foram usados e a rede não continha provider real.
- Implantação controlada: oito workflows seletivos foram importados, vinculados, publicados e ativados, incluindo `Library Agent Runtime`, `07 RAG Search` e `Starter 07 Maya Multi-Agent Orchestrator`. Os contratos estáticos terminaram com **38 passed**.
- Pós-implantação: sessão WAHA `default` em `WORKING`, inbound/outbound registrados, `WAHA_TEST_NUMBER` vazio e trava real desativada. Nenhuma mensagem real foi enviada nesta validação.
- Commit implantado: `68906e29203c777554ac133a2d447ff095de46a6`.
- Esta aprovação comprova a correção estrutural, os novos limites, o E2E simulado e a implantação. Não substitui uma futura homologação ponta a ponta com resposta automática real.

## E2E real WAHA — bloqueio por capacidade local (2026-09-18)

Status: **BLOCKED por capacidade local do planner; nenhuma nova otimização ou repetição autorizada**.

- Uma única mensagem real foi autorizada e enviada pelo segundo WhatsApp de teste. A entrada foi reconhecida pela nova janela E2E e persistida, comprovando a correção de identificação.
- A cadeia alcançou o `Ollama Agent Planner`, que excedeu exatamente o limite implantado de 240 s. O Ollama encerrou `POST /api/chat` com HTTP 500 após quatro minutos; a falha foi propagada por Agent Runtime, Maya e ingresso canônico.
- Nenhuma resposta outbound foi persistida ou entregue. O critério de homologação real não foi atingido.
- n8n, PostgreSQL, WAHA e provider-gateway permaneceram ativos; PostgreSQL, WAHA e gateway estavam saudáveis e não houve OOM.
- O cleanup fail-closed desativou a trava real, removeu o número autorizado e recriou WAHA/provider-gateway com sucesso.
- Decisão registrada: manter modelo, `num_ctx=2048`, `num_predict=256`, timeouts 240/540 s e recursos atuais. Não aumentar timeout, reduzir qualidade, trocar modelo ou mover inferência nesta etapa.
- O E2E isolado na AWS e a implantação permanecem aprovados. Somente a homologação ponta a ponta com resposta automática real fica **BLOCKED**.

## Google Calendar — homologação runtime aprovada (2026-09-19)

Status: **APPROVED**.

- A validação estática terminou com **11 passed**; o aviso de cache do pytest em filesystem read-only não afetou os testes.
- O smoke runtime confirmou disponibilidade, rejeição de autenticação inválida, gate de confirmação, idempotência persistente, criação, reagendamento e cancelamento.
- Foi criado um único evento temporário de homologação; o mesmo evento foi reagendado e cancelado pelo smoke.
- Nenhum evento permanente foi deixado na agenda.
- Os quatro adapters Calendar e o Policy Gateway permaneceram dentro do escopo; nenhum workflow fora do módulo foi alterado.
- A superfície final voltou para `https://assis.localhost`; a porta local 5678 não é necessária para a operação normal.


## Voz local — implantação e smoke runtime aprovado (2026-09-19)

Status: **APPROVED localmente**.

- Os workflows `Professional 11 Voice Ingress`, `Professional 17 Local STT`, `Professional 18 Local TTS` e `Professional 19 Voice Callback Adapter` foram importados, vinculados à credencial PostgreSQL, publicados e ativados.
- STT (`faster-whisper`, CPU/int8) e TTS (Kokoro, voz `pf_dora`) permaneceram ativos e o container STT reportou estado saudável.
- O smoke local gerou áudio sintético pelo TTS em memória e o enviou ao STT interno; foram retornados 127.244 bytes e transcrição em português.
- Nenhum áudio foi salvo, enviado a provedor externo ou associado a chamada real. WAHA, Calendar e os demais workflows permaneceram fora do escopo.
