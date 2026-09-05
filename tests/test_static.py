import json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def test_validate():
    p=subprocess.run([sys.executable,str(ROOT/'scripts/validate.py')],capture_output=True,text=True); assert p.returncode==0,p.stdout+p.stderr
def test_no_latest_tag(): assert 'n8nio/n8n:latest' not in (ROOT/'core/docker-compose.yml').read_text()
def test_all_workflows_inactive():
    for p in ROOT.rglob('workflows/*.json'):
        if p.name in {'manifest.json','catalog.json'}: continue
        assert json.loads(p.read_text()).get('active') is False
