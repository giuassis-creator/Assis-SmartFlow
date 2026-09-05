from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def test_golden_scenarios_defined():
    d=json.loads((ROOT/'tests/fixtures/golden-conversations.json').read_text()); assert len(d)>=8 and any(x['expected_route']=='handoff' for x in d) and any(x['expected_route']=='calendar' for x in d)
