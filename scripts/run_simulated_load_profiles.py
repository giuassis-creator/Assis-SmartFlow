"""Provision and run isolated load profiles using the approved Runtime.setup."""
import argparse, json, os, statistics, time, importlib.util
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
_spec=importlib.util.spec_from_file_location('approved_e2e_runtime', Path(__file__).resolve().parents[1]/'tests'/'test_waha_simulated_e2e.py')
_module=importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_module)
Runtime=_module.Runtime

REQUIRED = {'01 Canonical Ingress','02 Context Load','03 Memory Write','06 RAG Ingest','07 RAG Search',
            'Starter 07 Maya Multi-Agent Orchestrator','Starter 10 Simulated Provider'}

def stats(samples, started):
    values=sorted(samples); n=len(values)
    pick=lambda p: values[min(n-1, int(round((p/100)*(n-1))))] if values else 0
    return {'requests':n,'duration_s':round(time.perf_counter()-started,3),
            'throughput_rps':round(n/(time.perf_counter()-started),3),
            'latency_ms':{'min':min(values) if values else 0,'max':max(values) if values else 0,
                          'p50':pick(50),'p95':pick(95),'p99':pick(99)}}

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--diagnose-first-ingress',action='store_true'); parser.add_argument('--setup-only',action='store_true'); args=parser.parse_args()
    if os.getenv('ASSIS_E2E_SIMULATED')!='1': raise SystemExit('missing isolated marker')
    rt=Runtime(); evidence=Path(os.getenv('LOAD_EVIDENCE_PATH','.local/load-evidence.json')); evidence.parent.mkdir(parents=True,exist_ok=True)
    try:
        if args.diagnose_first_ingress:
            original=rt.inbound; captured=[]; before_exec=[]
            def traced(tenant,key,**extra):
                before_exec=rt.sql('SELECT id FROM execution_entity ORDER BY id')
                max_before=max((row[0] for row in before_exec), default=0)
                started=time.perf_counter(); status,body=original(tenant,key,**extra)
                time.sleep(2)
                new_exec=rt.sql('SELECT e.id,e.status,e."workflowId",e."startedAt",e."stoppedAt",w.name FROM execution_entity e JOIN workflow_entity w ON w.id=e."workflowId" WHERE e.id>%s ORDER BY e.id',(max_before,))
                details=[]
                for row in new_exec:
                    data=rt.sql('SELECT data FROM execution_data WHERE "executionId"=%s',(row[0],))
                    names=[]; last=None; codes=[]
                    if data:
                        try:
                            raw=data[0][0]; raw=json.loads(raw) if isinstance(raw,str) else raw
                            run=raw.get('resultData',{}).get('runData',{}) if isinstance(raw,dict) else {}
                            names=list(run.keys()); last=raw.get('resultData',{}).get('lastNodeExecuted') if isinstance(raw,dict) else None
                            for node_runs in run.values():
                                for execution in node_runs if isinstance(node_runs,list) else []:
                                    item=execution.get('data',{}) if isinstance(execution,dict) else {}
                                    if isinstance(item,dict) and 'responseCode' in item: codes.append(item.get('responseCode'))
                        except Exception: names=[]
                    details.append({'id':row[0],'status':row[1],'workflow_id':row[2],'workflow':row[5], 'started_at':str(row[3]),'stopped_at':str(row[4]),'nodes':names,'last_node':last,'response_codes':codes})
                captured.append({'status':status,'duration_ms':round((time.perf_counter()-started)*1000,2),
                    'body': body if isinstance(body,dict) else str(body)[:512], 'path':'/webhook/adapter/waha/in',
                    'execution_before_count':len(before_exec),'execution_before_max':max_before,
                    'execution_before_ids':[row[0] for row in before_exec],
                    'new_executions':details})
                return status,body
            rt.inbound=traced
        try: rt.setup()
        except Exception as exc:
            if args.diagnose_first_ingress:
                Path('/tmp/first-ingress.json').write_text(json.dumps({'error':type(exc).__name__,'ingress':captured[-1] if captured else None},indent=2),encoding='utf-8')
                print(json.dumps({'diagnosis':'first ingress failed','error':type(exc).__name__,'ingress':captured[-1] if captured else None},sort_keys=True)); return 2
            raise
        if args.diagnose_first_ingress or args.setup_only:
            if args.setup_only:
                before=rt.sql("SELECT (SELECT count(*) FROM organizations),(SELECT count(*) FROM organization_whatsapp_providers),(SELECT count(*) FROM conversations),(SELECT count(*) FROM messages),(SELECT count(*) FROM short_term_memory),(SELECT count(*) FROM knowledge_documents)")[0]
                rt.setup()
                after=rt.sql("SELECT (SELECT count(*) FROM organizations),(SELECT count(*) FROM organization_whatsapp_providers),(SELECT count(*) FROM conversations),(SELECT count(*) FROM messages),(SELECT count(*) FROM short_term_memory),(SELECT count(*) FROM knowledge_documents)")[0]
                if before != after: raise RuntimeError(f'Runtime.setup is not idempotent: before={before} after={after}')
                print(json.dumps({'setup':'passed','idempotent':True,'counts':list(after)},sort_keys=True))
            return 0
        before=rt.sql("SELECT (SELECT count(*) FROM organizations),(SELECT count(*) FROM organization_whatsapp_providers),(SELECT count(*) FROM conversations),(SELECT count(*) FROM messages),(SELECT count(*) FROM short_term_memory),(SELECT count(*) FROM knowledge_documents)")[0]
        rt.setup()
        after=rt.sql("SELECT (SELECT count(*) FROM organizations),(SELECT count(*) FROM organization_whatsapp_providers),(SELECT count(*) FROM conversations),(SELECT count(*) FROM messages),(SELECT count(*) FROM short_term_memory),(SELECT count(*) FROM knowledge_documents)")[0]
        if before != after: raise RuntimeError(f'Runtime.setup is not idempotent: before={before} after={after}')
        rows=rt.sql('SELECT name,active FROM workflow_entity WHERE name = ANY(%s)',(list(REQUIRED),))
        if {name for name,active in rows if active} != REQUIRED: raise RuntimeError('required workflow missing or inactive')
        out={'baseline':'local_hardware_only','profiles':{},'invariants':{'provider':'simulated','delivered':False},
             'metrics_unavailable':{'cpu_memory_swap_io':'Docker Desktop counters not exposed to QA container',
                'postgres_redis_queues':'collected only when service endpoints are configured'}}
        for name,count,concurrency in [('ingress_persistence_idempotency',10,2),('replay_concurrent',4,4),('rag',2,1),('maya_planner',2,1)]:
            key='load-'+name; started=time.perf_counter()
            def one(i):
                t=time.perf_counter(); result=rt.inbound(rt.tenants[0], key if 'replay' in name else f'{key}-{i}')
                return result,(time.perf_counter()-t)*1000
            with ThreadPoolExecutor(max_workers=concurrency) as pool: pairs=list(pool.map(one, range(count)))
            results=[pair[0] for pair in pairs]; lat=[pair[1] for pair in pairs]
            out['profiles'][name]={**stats(lat,started),'statuses':{str(s):sum(1 for code,_ in results if code==s) for s in {code for code,_ in results}},'errors':sum(code>=400 for code,_ in results)}
        out['invariants'].update({'unique_messages':rt.sql('SELECT count(*)=count(DISTINCT idempotency_key) FROM messages WHERE organization_id=%s',(rt.tenants[0]['org'],))[0][0]})
        evidence.write_text(json.dumps(out,indent=2),encoding='utf-8'); print(json.dumps(out,sort_keys=True)); return 0
    finally: rt.cleanup()

if __name__=='__main__': raise SystemExit(main())
