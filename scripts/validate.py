from pathlib import Path
import json,re,sys
from jsonschema import Draft202012Validator
ROOT=Path(__file__).resolve().parents[1]
errors=[]
for p in ROOT.rglob('*.json'):
    try: json.loads(p.read_text(encoding='utf-8'))
    except Exception as e: errors.append(f'{p}: invalid json: {e}')
secret_patterns=[r'ghp_[A-Za-z0-9]{20,}', r'sk-[A-Za-z0-9_-]{20,}', r'AKIA[0-9A-Z]{16}', r'(?i)api[_-]?key\s*[:=]\s*[A-Za-z0-9_-]{20,}']
for p in ROOT.rglob('*'):
    if p.is_file() and p.suffix.lower() in {'.json','.md','.yml','.yaml','.sql','.py','.example'}:
        txt=p.read_text(encoding='utf-8',errors='ignore')
        for pat in secret_patterns:
            if re.search(pat,txt): errors.append(f'{p}: possible committed secret ({pat})')
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
