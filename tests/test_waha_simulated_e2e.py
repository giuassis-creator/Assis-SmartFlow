"""Contract checks plus opt-in E2E against the isolated n8n runtime.

Run scripts/run_waha_simulated_e2e.py; the normal suite never calls a provider.
"""
import json
import os
from pathlib import Path
import uuid
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request, urlopen
from urllib.error import HTTPError

import pytest
from jsonschema import validate

ROOT = Path(__file__).resolve().parents[1]


def workflow(path):
    return json.loads((ROOT / path).read_text(encoding='utf-8'))


def nodes(path):
    return {n['name']:n for n in workflow(path)['nodes']}


def test_integration_starts_only_after_new_canonical_persistence():
    w = workflow('library/workflows/01-canonical-ingress.json')
    n = {n['name']:n for n in w['nodes']}
    persist = n['Persist Canonical Event']
    assert 'ON CONFLICT(organization_id,idempotency_key) DO NOTHING RETURNING *' in persist['parameters']['query']
    assert not persist.get('alwaysOutputData')
    assert w['connections']['Persist Canonical Event']['main'][0][0]['node'] == 'Prepare Simulated Turn'
    assert 'core-internal-agent' in n['Prepare Simulated Turn']['parameters']['jsCode']
    assert 'simulation' in n['Route Simulated Turn']['parameters']['conditions']['conditions'][0]['leftValue']


def test_simulated_provider_has_no_delivery_transport():
    w = workflow('starter/workflows/10-simulated-provider.json')
    urls = [n['parameters']['url'] for n in w['nodes'] if 'url' in n['parameters']]
    assert urls == ['http://n8n:5678/webhook/assis/internal/auth/verify']
    code = ' '.join(n['parameters'].get('jsCode','') for n in w['nodes'])
    assert 'simulation!==true' in code and 'valid!==true' in code
    assert "provider:'simulated'" in code and 'delivered:false' in code


def test_outbound_homologated_persistence_expression_is_unchanged():
    n = nodes('starter/workflows/06-outbound-text.json')
    expression = n['Persist Outbound Message']['parameters']['options']['queryReplacement']
    assert expression == "={{ [$json.organization_id,$json.conversation_id,$json.text,JSON.stringify({provider:$json.provider,provider_session:$json.provider_session,raw:$json.raw ?? null}),$json.provider_message_id ?? null,$json.idempotency_key] }}"
    assert '}}' not in expression[:-2]
    url = n['Send via Provider Gateway']['parameters']['url']
    assert "$json.simulation === true ? 'http://n8n:5678/webhook/assis/internal/message/simulate-provider'" in url
    assert " : 'http://provider-gateway:8080/v1/whatsapp/send-text'" in url


def test_simulation_cannot_execute_planner_tools_or_override_transport():
    runtime = nodes('library/agents/00-agent-runtime.json')
    assert 'tool_call:src.simulation===true?null:' in runtime['Prepare Tool Call']['parameters']['jsCode']
    assert 'conversation organization mismatch' in runtime['Prepare Planner Context']['parameters']['jsCode']
    policy = nodes('library/agents/09-tool-policy-gateway.json')['Policy + Route']['parameters']['jsCode']
    assert "b.simulation===true&&tool!=='message.send_text'" in policy
    assert 'payload:{...args,simulation:b.simulation===true' in policy


def test_waha_session_mapping_is_unambiguous_and_simulation_requires_core_auth():
    n = nodes('starter/workflows/08-waha-inbound.json')
    assert 'count(*)=1' in n['Resolve WAHA Organization']['parameters']['query']
    assert 'simulation&&!internal' in n['Prepare WAHA Auth']['parameters']['jsCode']
    assert 'simulation requires internal authentication' in nodes('library/workflows/01-canonical-ingress.json')['Authorize Canonical Ingress']['parameters']['jsCode']


def test_e2e_fixture_unloads_embedding_model_before_planner():
    source = Path(__file__).read_text(encoding='utf-8')
    assert "http://ollama:11434/api/embed" in source
    assert "'keep_alive':0" in source
    assert "unload nomic-embed-text" in source
    assert "status != 200" in source


def test_all_workflow_graphs_and_query_parameter_delimiters():
    for root in ['library','starter','professional','enterprise']:
        for path in (ROOT/root).rglob('*.json'):
            w = json.loads(path.read_text(encoding='utf-8'))
            if 'nodes' not in w:
                continue
            names = [n['name'] for n in w['nodes']]
            assert len(names) == len(set(names))
            for source, ports in w.get('connections', {}).items():
                assert source in names
                for groups in ports.values():
                    for group in groups:
                        for link in group:
                            assert link['node'] in names
            for n in w['nodes']:
                params = n.get('parameters',{}).get('options',{}).get('queryReplacement','')
                assert '}}' not in params[:-2], (path.name,n['name'])


RESULT_SCHEMA = {
    'type':'object', 'required':['ok','simulation','provider','organization_id',
        'conversation_id','response','context_loaded','rag_count','memory_written','idempotency_key'],
    'properties':{'ok':{'const':True}, 'simulation':{'const':True}, 'provider':{'const':'simulated'},
        'organization_id':{'type':'string'}, 'conversation_id':{'type':'string'},
        'response':{'type':'string','minLength':1,'maxLength':4096},
        'context_loaded':{'const':True}, 'rag_count':{'type':'integer','minimum':1},
        'memory_written':{'const':True}, 'idempotency_key':{'type':'string'}},
    'additionalProperties':False,
}


class Runtime:
    def __init__(self):
        import psycopg
        self.conn = psycopg.connect(host=os.environ['POSTGRES_HOST'], dbname=os.environ['POSTGRES_DB'],
            user=os.environ['POSTGRES_USER'], password=os.environ['POSTGRES_PASSWORD'], autocommit=True)
        self.token = os.environ['INTERNAL_AGENT_TOKEN']
        self.webhook = os.environ['WAHA_WEBHOOK_SECRET']
        self.base = os.environ['N8N_INTERNAL_URL']
        self.ids = []
        self.run_id = os.environ.get('ASSIS_E2E_RUN_ID') or os.environ.get('E2E_LOAD_PROJECT') or 'e2e-default'
        self.namespace = uuid.uuid5(uuid.NAMESPACE_URL, 'assis-smartflow:e2e:' + self.run_id)

    def sql(self, query, args=()):
        with self.conn.cursor() as cur:
            cur.execute(query,args)
            return cur.fetchall() if cur.description else []

    def request(self, url, body, headers=None, method='POST'):
        req = Request(url, data=json.dumps(body).encode(), method=method,
            headers={'Content-Type':'application/json', **(headers or {})})
        try:
            with urlopen(req,timeout=600) as response:
                raw=response.read()
                data=json.loads(raw) if raw else {}
                if isinstance(data,list):data=data[0] if data else {}
                return response.status,data
        except HTTPError as e:
            e.read()
            return e.code,{}

    def post(self,path,body,token=None):
        return self.request(self.base+path,body,{'x-assis-internal-token':self.token if token is None else token})

    def inbound(self,tenant,key,**extra):
        body={'event':'message','session':tenant['session'],'simulation':True,
              'payload':{'id':key,'from':'synthetic-contact@c.us','fromMe':False,
                         'body':'Informe o código de memória e o código da base de conhecimento.'}}
        body.update(extra)
        return self.request(self.base+'/webhook/adapter/waha/in',body,
            {'x-assis-secret':self.webhook,'x-assis-internal-token':self.token})

    def executions(self,name):
        return self.sql('SELECT count(*) FROM execution_entity e JOIN workflow_entity w ON w.id=e."workflowId" WHERE w.name=%s',(name,))[0][0]

    def unload_embedding_model(self):
        """Release the embedding runner before the planner in isolated E2E only."""
        def ollama(path, body=None):
            method = 'GET' if body is None else 'POST'
            request = Request('http://ollama:11434' + path,
                data=None if body is None else json.dumps(body).encode(),
                method=method, headers={'Content-Type':'application/json'})
            try:
                with urlopen(request, timeout=180) as response:
                    raw = response.read()
                    return response.status, json.loads(raw) if raw else {}
            except HTTPError as error:
                error.read()
                raise AssertionError(f'Ollama {path} failed with HTTP {error.code}') from error
            except Exception as error:
                raise AssertionError(f'Ollama {path} unavailable during E2E model unload: {error}') from error

        before_status, before = ollama('/api/ps')
        if before_status != 200:
            raise AssertionError(f'Ollama /api/ps returned HTTP {before_status} before embedding unload')
        unload_status, result = ollama('/api/embed',
            {'model':'nomic-embed-text','input':['e2e-unload-probe'],'keep_alive':0})
        if unload_status != 200:
            raise AssertionError(f'Ollama embedding unload returned HTTP {unload_status}')
        after_status, after = ollama('/api/ps')
        if after_status != 200:
            raise AssertionError(f'Ollama /api/ps returned HTTP {after_status} after embedding unload')
        resident = [m.get('name','') for m in after.get('models',[])]
        if any(name.startswith('nomic-embed-text') for name in resident):
            raise AssertionError('Ollama keep_alive=0 did not unload nomic-embed-text')
        print('E2E: unload nomic-embed-text; '
              f'before={len(before.get("models",[]))} after={resident} '
              f'http={unload_status} load_ms={result.get("load_duration",0)/1e6:.1f}', flush=True)

    def setup(self):
        status,_ = self.request('http://qdrant:6333/collections/assis_knowledge',
                               {'vectors':{'size':768,'distance':'Cosine'}},method='PUT')
        assert status in (200,409)
        self.tenants=[]
        for label,code in [('a','ALFA-AZUL'),('b','BETA-VERDE')]:
            org=str(uuid.uuid5(self.namespace, 'organization:'+label));slug='e2e-simulated-'+self.run_id+'-'+label;session='e2e-'+self.run_id+'-'+label
            self.sql('INSERT INTO organizations(id,slug,name,config) VALUES(%s,%s,%s,%s::jsonb) ON CONFLICT (id) DO UPDATE SET slug=EXCLUDED.slug,config=EXCLUDED.config',
                     (org,slug,'Simulated E2E',json.dumps({'smoke_test':True,'run_id':self.run_id})))
            self.ids.append(org)
            self.sql("INSERT INTO organization_whatsapp_providers(organization_id,provider,session_name,enabled) VALUES(%s,'waha',%s,true) ON CONFLICT (organization_id,provider,session_name) DO UPDATE SET enabled=true",(org,session))
            tenant={'org':org,'session':session,'code':code,'rag_code':'BASE-'+code}
            status,_ = self.inbound(tenant,'seed-'+label,simulation=False)
            assert status==200
            conv=self.sql('SELECT id FROM conversations WHERE organization_id=%s',(org,))[0][0]
            tenant['conv']=str(conv)
            self.sql('INSERT INTO short_term_memory(conversation_id,summary) VALUES(%s,%s) ON CONFLICT (conversation_id) DO UPDATE SET summary=EXCLUDED.summary',
                     (conv,'O código de memória é '+code+'.'))
            status,_=self.post('/webhook/internal/rag/ingest',{'organization_id':org,
                'title':'Código da base de conhecimento','content':'O código da base de conhecimento desta organização é BASE-'+code+'.',
                'checksum':'e2e-'+self.run_id+'-'+label,'metadata':{'smoke_test':True,'run_id':self.run_id}})
            assert status==200
            self.tenants.append(tenant)
        self.unload_embedding_model()
        a=self.tenants[0]
        self.success_key='complete-'+str(uuid.uuid4())
        status,self.success=self.inbound(a,self.success_key)
        assert status==200, 'simulated full chain failed'
        validate(self.success,RESULT_SCHEMA)

    def cleanup(self):
        for org in self.ids:
            self.request('http://qdrant:6333/collections/assis_knowledge/points/delete?wait=true',
                {'filter':{'must':[{'key':'organization_id','match':{'value':org}}]}})
            self.sql('DELETE FROM tool_idempotency WHERE organization_id=%s',(org,))
            self.sql('DELETE FROM organizations WHERE id=%s',(org,))
        self.conn.close()


@pytest.fixture(scope='class')
def rt():
    runtime=Runtime()
    try:
        runtime.setup()
        yield runtime
    finally:
        runtime.cleanup()


@pytest.mark.skipif(os.getenv('ASSIS_E2E_SIMULATED')!='1', reason='isolated runtime required')
class TestSimulatedRuntime:
    def test_complete_flow_and_context_rag(self,rt):
        a=rt.tenants[0];r=rt.success
        assert r['organization_id']==a['org'] and r['conversation_id']==a['conv']
        assert a['code'] in r['response']
        assert a['rag_code'] in r['response']
        assert rt.tenants[1]['code'] not in r['response']
        rows=rt.sql("SELECT payload->>'provider',provider_message_id FROM messages WHERE organization_id=%s AND idempotency_key=%s",(a['org'],r['idempotency_key']))
        assert rows==[('simulated',None)]
        assert rt.sql('SELECT status FROM tool_idempotency WHERE organization_id=%s AND idempotency_key=%s',(a['org'],r['idempotency_key']))==[('completed',)]

    def test_duplicate_never_reaches_maya_or_provider(self,rt):
        names=['Starter 07 Maya Multi-Agent Orchestrator','Starter 10 Simulated Provider']
        counts=[rt.executions(n) for n in names]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda _:rt.inbound(rt.tenants[0],rt.success_key),range(2)))
        assert all(status==200 for status,_ in results)
        assert all(r.get('ok') is True and r.get('duplicate') is True for _,r in results)
        assert rt.sql('SELECT count(*) FROM messages WHERE organization_id=%s AND idempotency_key=%s',
            (rt.tenants[0]['org'],rt.success_key))==[(1,)]
        assert rt.sql('SELECT count(*) FROM messages WHERE organization_id=%s AND idempotency_key=%s',
            (rt.tenants[0]['org'],rt.success['idempotency_key']))==[(1,)]
        assert [rt.executions(n) for n in names]==counts

    def test_organization_isolation_and_spoofed_ids(self,rt):
        a,b=rt.tenants
        status,r=rt.inbound(b,rt.success_key,organization_id=a['org'],conversation_id=a['conv'])
        assert status==200
        validate(r,RESULT_SCHEMA)
        assert r['organization_id']==b['org'] and r['conversation_id']==b['conv']
        assert b['code'] in r['response'] and a['code'] not in r['response']
        assert b['rag_code'] in r['response']
        count=rt.executions('Starter 10 Simulated Provider')
        status,r=rt.post('/webhook/assis/internal/message/send-text',{'simulation':True,
            'organization_id':a['org'],'conversation_id':b['conv'],'idempotency_key':'wrong-scope',
            'to':'synthetic-contact@c.us','text':'blocked'})
        assert status>=400 or r.get('ok') is not True
        assert rt.executions('Starter 10 Simulated Provider')==count
        assert rt.sql("SELECT count(*) FROM tool_idempotency WHERE idempotency_key='wrong-scope'")==[(0,)]

    def test_invalid_authentication_has_no_business_effects(self,rt):
        before=rt.sql('SELECT count(*) FROM messages')[0][0]
        counts=rt.executions('Starter 07 Maya Multi-Agent Orchestrator')
        for provider_token,core_token in [('invalid',rt.token),(rt.webhook,'invalid'),(rt.webhook,'')]:
            status,r=rt.request(rt.base+'/webhook/adapter/waha/in',{'simulation':True,'event':'message',
                'session':rt.tenants[0]['session'],'payload':{'id':str(uuid.uuid4()),'from':'synthetic-contact@c.us','body':'blocked'}},
                {'x-assis-secret':provider_token,'x-assis-internal-token':core_token})
            assert status>=400 or r.get('ok') is not True
        assert rt.sql('SELECT count(*) FROM messages')[0][0]==before
        assert rt.executions('Starter 07 Maya Multi-Agent Orchestrator')==counts

    def test_provider_failure_is_at_most_once_and_not_persisted_as_success(self,rt):
        a=rt.tenants[0];key='failure-'+str(uuid.uuid4())
        status,r=rt.inbound(a,key,simulate_failure=True)
        assert status>=400 or r.get('ok') is not True
        message=rt.sql('SELECT id FROM messages WHERE organization_id=%s AND idempotency_key=%s',(a['org'],key))[0][0]
        outgoing='simulated-reply:'+str(message)
        assert rt.sql('SELECT count(*) FROM messages WHERE organization_id=%s AND idempotency_key=%s',(a['org'],outgoing))==[(0,)]
        assert rt.sql('SELECT status FROM tool_idempotency WHERE organization_id=%s AND idempotency_key=%s',(a['org'],outgoing))==[('claimed',)]
        count=rt.executions('Starter 07 Maya Multi-Agent Orchestrator')
        status,replay=rt.inbound(a,key)
        assert status==200 and replay.get('duplicate') is True
        assert rt.executions('Starter 07 Maya Multi-Agent Orchestrator')==count

    def test_normal_waha_event_is_persist_only(self,rt):
        count=rt.executions('Starter 07 Maya Multi-Agent Orchestrator')
        status,_=rt.inbound(rt.tenants[0],'ordinary-'+str(uuid.uuid4()),simulation=False)
        assert status==200
        assert rt.executions('Starter 07 Maya Multi-Agent Orchestrator')==count

    def test_policy_simulation_cannot_be_overridden_by_tool_arguments(self,rt):
        a=rt.tenants[0]
        status,r=rt.post('/webhook/assis/internal/tool/execute',{'simulation':True,
            'agent_id':'reception.agent','organization_id':a['org'],'conversation_id':a['conv'],
            'idempotency_key':'policy-'+str(uuid.uuid4()),'tool_call':{'name':'message.send_text',
                'arguments':{'simulation':False,'to':'synthetic-contact@c.us','text':'simulated only'}}})
        assert status==200 and r.get('provider')=='simulated'
        status,r=rt.post('/webhook/assis/internal/tool/execute',{'simulation':True,
            'agent_id':'calendar.agent','confirmed':True,'tool_call':{'name':'calendar.book','arguments':{}}})
        assert status==200 and r.get('executed') is False
