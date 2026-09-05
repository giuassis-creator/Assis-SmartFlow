import json
from pathlib import Path
from jsonschema import validate
ROOT=Path(__file__).resolve().parents[1]
def test_secretary_profile_contract():
    schema=json.loads((ROOT/'core/config/secretary-profile.schema.json').read_text())
    sample={'organization_name':'Clínica Exemplo','secretary_name':'Maya','role_label':'Secretária','never_self_identify_as_ai':True,'tone':['cordial','paciente','natural']}
    validate(sample,schema)
def test_handoff_has_history_policy():
    txt=(ROOT/'library/workflows/04-handoff.json').read_text(); assert 'recent_messages' in txt and 'slice(-20)' in txt
