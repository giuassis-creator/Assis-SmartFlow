from pathlib import Path
import json,re,sys
from jsonschema import Draft202012Validator
ROOT=Path(__file__).resolve().parents[1]
errors=[]
for p in ROOT.rglob('*.json'):
    try: json.loads(p.read_text(encoding='utf-8'))
    except Exception as e: errors.append(f'{p}: invalid json: {e}')
secret_patterns=[r'ghp_[A-Za-z0-9]{20,}', r'sk-[A-Za-z0-9_-]{20,}', r'AKIA[0-9A-Z]{16}', r'(?i)api[_-]?key\s*[:=]\s*[A-Za-z0-9_-]{20,}']
# Exact values for credential assignments in the root environment template only.
# Never allow arbitrary strings merely because they contain CHANGE_ME.
template_placeholders = {
    'INTERNAL_AGENT_TOKEN': 'CHANGE_ME_LONG_RANDOM_INTERNAL_TOKEN',
    'POSTGRES_PASSWORD': 'CHANGE_ME_LONG_RANDOM',
    'REDIS_PASSWORD': 'CHANGE_ME_LONG_RANDOM',
    'N8N_ENCRYPTION_KEY': 'CHANGE_ME_64_CHAR_RANDOM',
    'WAHA_API_KEY': 'CHANGE_ME_LONG_RANDOM_WAHA_API_KEY',
    'WAHA_WEBHOOK_SECRET': 'CHANGE_ME_LONG_RANDOM_WAHA_WEBHOOK_SECRET',
    'WAHA_DASHBOARD_PASSWORD': 'CHANGE_ME_LONG_RANDOM_WAHA_DASHBOARD_PASSWORD',
    'EVOLUTION_WEBHOOK_SECRET': 'CHANGE_ME_LONG_RANDOM_EVOLUTION_SECRET',
    'CHATWOOT_WEBHOOK_SECRET': 'CHANGE_ME_LONG_RANDOM_CHATWOOT_SECRET',
    'DB_POSTGRESDB_PASSWORD': '${POSTGRES_PASSWORD}',
    'EVOLUTION_API_KEY': '',
    'S3_ACCESS_KEY': '',
    'S3_SECRET_KEY': '',
}

def secret_findings(path, text):
    findings = []
    scanned_lines = []
    for line in text.splitlines(keepends=True):
        assignment = re.fullmatch(r'([A-Z][A-Z0-9_]*)=(.*)', line.rstrip('\r\n'))
        if path == ROOT / '.env.example' and assignment:
            key, value = assignment.groups()
            if key in template_placeholders:
                if value in {'CHANGE_ME', template_placeholders[key]}:
                    scanned_lines.append('\n')
                    continue
                if value:
                    findings.append(f'unrecognized credential value for {key}')
        scanned_lines.append(line)
    scanned = ''.join(scanned_lines)
    findings.extend(pat for pat in secret_patterns if re.search(pat, scanned))
    return findings

for p in ROOT.rglob('*'):
    if p.is_file() and p.suffix.lower() in {'.json','.md','.yml','.yaml','.sql','.py','.example'}:
        txt=p.read_text(encoding='utf-8',errors='ignore')
        for finding in secret_findings(p, txt):
            errors.append(f'{p}: possible committed secret ({finding})')
for pack in ['starter','professional','enterprise']:
    mf=ROOT/pack/'workflows/manifest.json'
    if mf.exists():
        data=json.loads(mf.read_text())
        for f in data.get('workflows',[]):
            if not (mf.parent/f).exists(): errors.append(f'{mf}: missing workflow {f}')
for p in (ROOT/'mcp/catalog').glob('*.json'):
    d=json.loads(p.read_text());
    for k in ['name','version','tier','input','output','timeout_ms','idempotent']:
        if k not in d: errors.append(f'{p}: missing {k}')
if errors:
    print('\n'.join('ERROR '+e for e in errors));sys.exit(1)
print('PASS: static validation')
