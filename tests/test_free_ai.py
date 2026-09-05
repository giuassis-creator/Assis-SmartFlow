from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def test_free_ai_env_defaults():
    text=(ROOT/'.env.example').read_text(); assert 'AI_PROVIDER=ollama' in text and 'AI_ALLOW_PAID_FALLBACK=false' in text and 'OLLAMA_CHAT_MODEL=qwen3:4b-instruct' in text
def test_compose_has_local_ai_services():
    text=(ROOT/'core/docker-compose.yml').read_text(); assert all(x in text for x in ['  ollama:','  stt:','  tts:'])
def test_local_ai_workflows_parse():
    for p in [ROOT/'library/workflows/09-local-ai-chat.json',ROOT/'library/workflows/10-local-embeddings.json',ROOT/'professional/workflows/17-local-stt.json',ROOT/'professional/workflows/18-local-tts.json']: assert json.loads(p.read_text())['nodes']
def test_no_paid_llm_required():
    env=(ROOT/'.env.example').read_text().lower(); assert 'openai_api_key' not in env and 'anthropic_api_key' not in env
