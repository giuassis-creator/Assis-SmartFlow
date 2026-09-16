"""End-to-end isolated bootstrap, publication and load lifecycle.

Every destination is explicit and validated before Docker is invoked.
"""
import hashlib, json, os, secrets, subprocess, sys, time, uuid
from types import SimpleNamespace
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PROJECT=os.environ.get('E2E_LOAD_PROJECT','assis-smartflow-load-run')
VOLUME=os.environ.get('E2E_MODEL_VOLUME') or 'assis-smartflow-e2e-ollama-cache'
MARKER='ASSIS_E2E_SIMULATED'
PATHS=['library/agents/11-internal-auth-verify.json','library/agents/10-tool-noop.json','library/agents/09-tool-policy-gateway.json','library/agents/00-agent-runtime.json','library/workflows/01-canonical-ingress.json','library/workflows/02-context-load.json','library/workflows/03-memory-write.json','library/workflows/06-rag-ingest.json','library/workflows/07-rag-search.json','library/workflows/13-auto-memory-capture.json','starter/workflows/07-multi-agent-orchestrator.json','starter/workflows/08-waha-inbound.json','starter/workflows/06-outbound-text.json','starter/workflows/10-simulated-provider.json']

def guard():
    if os.getenv('ASSIS_E2E_SIMULATED')!='1': raise RuntimeError('ASSIS_E2E_SIMULATED=1 required')
    if not PROJECT.startswith('assis-smartflow-load-') or PROJECT=='assis-smartflow': raise RuntimeError('invalid isolated project')
    if not (VOLUME.startswith('assis-smartflow-load-ollama-') or VOLUME == 'assis-smartflow-e2e-ollama-cache') or VOLUME=='assis-smartflow_ollama_data': raise RuntimeError('invalid temporary model volume')
    if os.getenv('ASSIS_DOMAIN') or any(x in os.getenv('N8N_INTERNAL_URL','') for x in ['assis','https://','http://domain']): raise RuntimeError('production endpoint rejected')

def run(args, env, input_text=None, check=True, timeout=None):
    try:
        r=subprocess.run(args,input=input_text,text=True,capture_output=True,encoding='utf-8',cwd=ROOT,env=env,timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        r=SimpleNamespace(returncode=124,stdout=(exc.stdout or ''),stderr=(exc.stderr or '')+'readiness attempt timeout')
    if check and r.returncode: raise RuntimeError(f'command failed: {args[0]} {args[1:3]}')
    return r

def ensure_model_cache(env):
    """Create/validate the persistent E2E-only cache; never touch production volume."""
    if VOLUME == 'assis-smartflow_ollama_data' or VOLUME.startswith('assis-smartflow_') and VOLUME.startswith('assis-smartflow_ollama_data'):
        raise RuntimeError('production Ollama volume rejected')
    listed=run(['docker','volume','inspect',VOLUME],env,check=False)
    if listed.returncode:
        created=run(['docker','volume','create','--label','assis.e2e.purpose=ollama-model-cache','--label','assis.e2e.production=false','--label','assis.e2e.owner=simulated-load-harness',VOLUME],env,check=False)
        if created.returncode: raise RuntimeError('E2E model cache creation failed')
    inspected=run(['docker','volume','inspect','--format','{{json .Labels}}',VOLUME],env,check=False)
    try: labels=json.loads(inspected.stdout)
    except Exception: labels={}
    if labels.get('assis.e2e.purpose')!='ollama-model-cache' or labels.get('assis.e2e.production')!='false' or labels.get('assis.e2e.owner')!='simulated-load-harness':
        raise RuntimeError('E2E model cache labels invalid')

def provision_models(env, private):
    ensure_model_cache(env)
    name=PROJECT+'-model-pull'; stdout=private/'model-pull.stdout.log'; stderr=private/'model-pull.stderr.log'; codes=private/'model-pull.exitcodes.jsonl'
    run(['docker','rm','-f',name],env,check=False)
    start=run(['docker','run','-d','--label','assis.e2e.simulated=true','--label','assis.e2e.owner=simulated-load-harness','--name',name,'-v',VOLUME+':/root/.ollama','ollama/ollama:0.33.3'],env,check=False)
    if start.returncode: raise RuntimeError('Ollama model daemon failed to start')
    ready=False
    for _ in range(30):
        probe=run(['docker','exec',name,'ollama','list'],env,check=False,timeout=10)
        with stdout.open('a',encoding='utf-8') as f: f.write(probe.stdout)
        with stderr.open('a',encoding='utf-8') as f: f.write(probe.stderr)
        with codes.open('a',encoding='utf-8') as f: f.write(json.dumps({'command':'ollama list','exit_code':probe.returncode})+'\n')
        if probe.returncode==0: ready=True; break
        time.sleep(2)
    if not ready: raise RuntimeError('Ollama daemon did not become ready before model pull')
    for model in ('qwen3:4b-instruct','nomic-embed-text:latest'):
        success=False
        for attempt in range(1,4):
            pull=run(['docker','exec',name,'ollama','pull',model],env,check=False,timeout=1200)
            with stdout.open('a',encoding='utf-8') as f: f.write(pull.stdout)
            with stderr.open('a',encoding='utf-8') as f: f.write(pull.stderr)
            with codes.open('a',encoding='utf-8') as f: f.write(json.dumps({'command':'ollama pull','model':model,'attempt':attempt,'exit_code':pull.returncode})+'\n')
            if pull.returncode==0: success=True; break
        if not success: raise RuntimeError('model pull failed: '+model)
    final=run(['docker','exec',name,'ollama','list'],env,check=False)
    with stdout.open('a',encoding='utf-8') as f: f.write(final.stdout)
    with stderr.open('a',encoding='utf-8') as f: f.write(final.stderr)
    if final.returncode: raise RuntimeError('final Ollama model listing failed')
    (private/'model-list.txt').write_text(final.stdout,encoding='utf-8')
    return name

def wait_ready(compose, env, log, timeout=300):
    deadline=time.time()+timeout
    diagnostics=log.with_name('readiness-pollings.jsonl')
    diagnostics.write_text('', encoding='utf-8')
    while time.time()<deadline:
        stamp=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        ident=run(compose+['ps','-q','n8n'],env,check=False)
        cid=ident.stdout.strip().splitlines()[-1] if ident.stdout.strip() else None
        state={}
        if cid:
            inspected=run(['docker','inspect','--format','{{json .State}}',cid],env,check=False)
            try: state=json.loads(inspected.stdout)
            except Exception: state={'inspect_error': inspected.stderr.strip()[:160]}
        if not cid or state.get('Status') in {'exited','dead'}:
            raise RuntimeError('isolated n8n container is not running during readiness')
        if isinstance(state.get('Health'),dict) and state['Health'].get('Status') == 'unhealthy':
            raise RuntimeError('isolated n8n container unhealthy during readiness')
        r=run(compose+['exec','-T','n8n','node','-e',"fetch('http://127.0.0.1:5678/healthz/readiness').then(async r=>{console.log('HTTP '+r.status);process.exit(r.ok?0:1)}).catch(e=>{console.error(e.name);process.exit(2)})"],env,check=False,timeout=10)
        with log.open('a',encoding='utf-8') as stream:
            stream.write(r.stdout)
        with log.with_name('readiness-stdout.log').open('a',encoding='utf-8') as stream: stream.write(r.stdout)
        with log.with_name('readiness-stderr.log').open('a',encoding='utf-8') as stream: stream.write(r.stderr)
        record={'timestamp':stamp,'container_id':cid,'state_status':state.get('Status'),'health_status':state.get('Health',{}).get('Status') if isinstance(state.get('Health'),dict) else None,'restart_count':state.get('RestartCount'),'exit_code':state.get('ExitCode'),'readiness_exit_code':r.returncode,'endpoint':'http://127.0.0.1:5678/healthz/readiness','stdout_class':r.stdout.strip()[:80],'stderr_class':r.stderr.strip()[:160]}
        with diagnostics.open('a',encoding='utf-8') as stream: stream.write(json.dumps(record)+'\n')
        if r.returncode==0 and r.stdout.strip() == 'HTTP 200':
            body=run(compose+['exec','-T','n8n','node','-e',"fetch('http://127.0.0.1:5678/healthz/readiness').then(async r=>{let t=await r.text(); process.stdout.write(t); process.exit(r.status===200 && t.trim()==='{\"status\":\"ok\"}'?0:1)}).catch(()=>process.exit(2))"],env,check=False,timeout=10)
            if body.returncode==0: return
        time.sleep(2)
    raise RuntimeError('isolated n8n readiness timeout after restart')

def main():
    guard(); private=ROOT/'.local'/'load-isolated'; private.mkdir(parents=True,exist_ok=True)
    env=dict(os.environ); env.update({'E2E_DB_PASSWORD':secrets.token_hex(32),'E2E_ENCRYPTION_KEY':secrets.token_hex(32),'E2E_INTERNAL_TOKEN':secrets.token_hex(32),'E2E_WEBHOOK_SECRET':secrets.token_hex(32),'E2E_MODEL_VOLUME':VOLUME,'E2E_LOAD_PORT':os.getenv('E2E_LOAD_PORT','5691'),'ASSIS_E2E_RUN_ID':PROJECT})
    empty=private/'empty.env'; empty.write_text('')
    compose=['docker','compose','--env-file',str(empty),'-p',PROJECT,'-f',str(ROOT/'core/docker-compose.e2e-simulated.yml'),'-f',str(ROOT/'core/docker-compose.load-simulated.override.yml')]
    log=private/'lifecycle.log'; log.write_text('')
    def c(args,data=None,check=True):
        r=run(compose+args,env,data,False)
        with log.open('a',encoding='utf-8') as stream: stream.write(r.stdout+r.stderr)
        if check and r.returncode: raise RuntimeError(f'command failed (exit {r.returncode}): {r.stderr[-800:]}')
        return r
    try:
        provision_models(env, private)
        c(['config'])
        pull_name=PROJECT+'-model-pull'
        run(['docker','rm','-f',pull_name],env)
        c(['up','-d','postgres','n8n','qdrant','ollama','embed-proxy'])
        c(['exec','-T','postgres','psql','-U','assis_e2e','-d','assis_e2e','-c','select 1'])
        workflows=[]
        for rel in PATHS:
            w=json.loads((ROOT/rel).read_text(encoding='utf-8'))
            for node in w.get('nodes',[]):
                if node.get('parameters',{}).get('url','').endswith('/api/embed'):
                    node['parameters']['url']='http://embed-proxy:11434/api/embed'
            w['id']=str(uuid.uuid5(uuid.NAMESPACE_URL,rel)); w['versionId']=str(uuid.uuid5(uuid.NAMESPACE_URL,'version:'+rel)); workflows.append(w)
        cred=[{'id':'ASSIS_POSTGRES','name':'Assis PostgreSQL E2E','type':'postgres','data':{'host':'postgres','port':5432,'database':'assis_e2e','user':'assis_e2e','password':env['E2E_DB_PASSWORD'],'ssl':'disable'}}]
        def write(path,obj):
            code="let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>require('fs').writeFileSync(process.argv[1],s))"
            c(['exec','-T','n8n','node','-e',code,path],json.dumps(obj))
        write('/tmp/load-credentials.json',cred); c(['exec','-T','n8n','n8n','import:credentials','--input=/tmp/load-credentials.json'])
        write('/tmp/load-workflows.json',workflows); c(['exec','-T','n8n','n8n','import:workflow','--input=/tmp/load-workflows.json'])
        for name,key in [('core-internal-agent','E2E_INTERNAL_TOKEN'),('waha-webhook','E2E_WEBHOOK_SECRET')]:
            digest=hashlib.sha256(env[key].encode()).hexdigest()
            c(['exec','-T','postgres','psql','-U','assis_e2e','-d','assis_e2e','-c',
               "INSERT INTO internal_auth_secrets(name,token_sha256) VALUES ('%s','%s') ON CONFLICT (name) DO UPDATE SET token_sha256=EXCLUDED.token_sha256;"%(name,digest)])
        for w in workflows: c(['exec','-T','n8n','n8n','publish:workflow','--id='+w['id']])
        # n8n loads published workflow versions on process start.
        c(['restart','n8n'])
        wait_ready(compose,env,log)
        (private/'manifest.json').write_text(json.dumps({'project':PROJECT,'volume':VOLUME,'workflows':[w['id'] for w in workflows]}),encoding='utf-8')
        profile_args=['run','--rm','qa','python','scripts/run_simulated_load_profiles.py']
        if os.getenv('LOAD_DIAGNOSE_FIRST_INGRESS')=='1': profile_args.append('--diagnose-first-ingress')
        if os.getenv('LOAD_SETUP_ONLY')=='1': profile_args.append('--setup-only')
        diag_result=c(profile_args,check=False)
        if os.getenv('LOAD_DIAGNOSE_FIRST_INGRESS')=='1':
            q=c(['exec','-T','postgres','psql','-U','assis_e2e','-d','assis_e2e','-At','-c',
                "SELECT e.id,e.status,e.\"workflowId\",e.\"startedAt\",e.\"stoppedAt\" FROM execution_entity e ORDER BY e.\"startedAt\" DESC LIMIT 5;"],check=False)
            (private/'execution-metadata.txt').write_text(q.stdout,encoding='utf-8')
            c(['logs','--no-color','--tail=120','n8n'],check=False)
            print('DIAGNOSTIC_EXIT='+str(diag_result.returncode))
        elif diag_result.returncode: raise RuntimeError('load profiles failed')
        print('PASS: isolated bootstrap and load lifecycle')
    finally:
        c(['down'],check=False)
        run(['docker','rm','-f',PROJECT+'-model-pull'],env,check=False)
        # The explicitly labelled E2E model cache is persistent by design.

if __name__=='__main__': main()
