"""Run the actual n8n/PostgreSQL/Ollama/Qdrant chain without a real provider.

The dedicated Compose project has no external network, ports or production DB.
Only model weights are reused read-only. Logs stay in ignored .local storage.
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'assis-smartflow-e2e-simulated'
PATHS = [
    'library/agents/11-internal-auth-verify.json',
    'library/agents/10-tool-noop.json',
    'library/agents/09-tool-policy-gateway.json',
    'library/agents/00-agent-runtime.json',
    'library/workflows/01-canonical-ingress.json',
    'library/workflows/02-context-load.json',
    'library/workflows/03-memory-write.json',
    'library/workflows/06-rag-ingest.json',
    'library/workflows/07-rag-search.json',
    'library/workflows/13-auto-memory-capture.json',
    'starter/workflows/07-multi-agent-orchestrator.json',
    'starter/workflows/08-waha-inbound.json',
    'starter/workflows/06-outbound-text.json',
    'starter/workflows/10-simulated-provider.json',
]


def main():
    private = ROOT / '.local' / 'e2e-simulated'
    private.mkdir(parents=True, exist_ok=True)
    empty_env = private / 'empty.env'
    empty_env.write_text('')
    env = dict(os.environ)
    for key in ['DB_PASSWORD', 'ENCRYPTION_KEY', 'INTERNAL_TOKEN', 'WEBHOOK_SECRET']:
        env['E2E_' + key] = secrets.token_hex(32)
    compose = ['docker', 'compose', '--env-file', str(empty_env), '-p', PROJECT,
               '-f', str(ROOT / 'core/docker-compose.e2e-simulated.yml')]
    log = private / 'run.log'
    log.write_text('')

    def run(args, data=None, check=True):
        result = subprocess.run(args, input=data, capture_output=True, text=True,
                                encoding='utf-8', env=env, cwd=ROOT)
        with log.open('a', encoding='utf-8') as f:
            f.write(result.stdout + result.stderr)
        if check and result.returncode:
            raise RuntimeError('Isolated E2E command failed; inspect private run.log')
        return result

    def pg(sql):
        return run(compose + ['exec', '-T', 'postgres', 'psql', '-v', 'ON_ERROR_STOP=1',
                              '-U', 'assis_e2e', '-d', 'assis_e2e', '-At'], sql).stdout.strip()

    def wait_ready():
        for _ in range(60):
            r = run(compose + ['exec', '-T', 'n8n', 'node', '-e',
                "fetch('http://127.0.0.1:5678/healthz/readiness').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"], check=False)
            if r.returncode == 0:
                return
            time.sleep(2)
        raise RuntimeError('Isolated n8n readiness timeout')

    existing = run(compose + ['ps', '-aq']).stdout.strip()
    if existing:
        raise RuntimeError('Dedicated test project already exists; inspect before reusing')
    try:
        print('E2E: starting isolated services; production volumes remain untouched', flush=True)
        run(compose + ['up', '-d', 'postgres', 'n8n', 'qdrant', 'ollama'])
        wait_ready()
        # Synthetic credentials only; never export production credentials.
        credential = [{'id':'ASSIS_POSTGRES', 'name':'Assis PostgreSQL', 'type':'postgres',
                       'data':{'host':'postgres', 'port':5432, 'database':'assis_e2e',
                               'user':'assis_e2e', 'password':env['E2E_DB_PASSWORD'], 'ssl':'disable'}}]
        def write_container(path, value):
            run(compose + ['exec', '-T', 'n8n', 'node', '-e',
                "let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>require('fs').writeFileSync(process.argv[1],s))", path], json.dumps(value))
        write_container('/tmp/e2e-credentials.json', credential)
        run(compose + ['exec', '-T', 'n8n', 'n8n', 'import:credentials', '--input=/tmp/e2e-credentials.json'])
        workflows = []
        for path in PATHS:
            w = json.loads((ROOT / path).read_text(encoding='utf-8'))
            w['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, path))
            w['versionId'] = str(uuid.uuid4())
            workflows.append(w)
        write_container('/tmp/e2e-workflows.json', workflows)
        run(compose + ['exec', '-T', 'n8n', 'n8n', 'import:workflow', '--input=/tmp/e2e-workflows.json'])
        for name, key in [('core-internal-agent','E2E_INTERNAL_TOKEN'), ('waha-webhook','E2E_WEBHOOK_SECRET')]:
            digest = hashlib.sha256(env[key].encode()).hexdigest()
            pg(f"INSERT INTO internal_auth_secrets(name,token_sha256) VALUES('{name}','{digest}');")
        for w in workflows:
            run(compose + ['exec', '-T', 'n8n', 'n8n', 'publish:workflow', '--id=' + w['id']])
        run(compose + ['restart', 'n8n'])
        wait_ready()
        # Match the existing warm-local-ai.ps1 prerequisite: the first planner
        # request must not also pay for loading the model into memory.
        print('E2E: warming local model before timed workflow requests', flush=True)
        run(compose + ['exec', '-T', 'ollama', 'ollama', 'run',
                       'qwen3:4b-instruct', 'Responda somente: OK'])
        print('E2E: running structural validation and complete suite with actual local models', flush=True)
        r = run(compose + ['run', '--rm', 'qa', 'sh', '-c',
                           'python scripts/validate.py && pytest -q -p no:cacheprovider'], check=False)
        # Only aggregate summaries, never provider payloads, reach the console.
        for line in r.stdout.splitlines():
            if line.startswith('PASS:') or (' passed' in line and not line.startswith(' ')):
                print(line, flush=True)
        if r.returncode:
            run(compose + ['logs', '--no-color', '--tail=120', 'n8n', 'ollama', 'postgres'], check=False)
            pg('SELECT d.data FROM execution_data d JOIN execution_entity e ON e.id=d."executionId" WHERE e.status=\'error\';')
            raise RuntimeError('Isolated E2E suite failed; inspect private run.log')
        print('PASS: isolated simulated E2E; no real provider exists on this network', flush=True)
    finally:
        # Exact dedicated project only; no volume deletion (model cache is external).
        run(compose + ['down'], check=True)


if __name__ == '__main__':
    main()
