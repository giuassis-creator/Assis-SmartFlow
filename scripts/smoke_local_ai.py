import json
import os
import time
import urllib.request

OLLAMA = os.getenv("OLLAMA_INTERNAL_URL", "http://ollama:11434")
STT = os.getenv("STT_INTERNAL_URL", "http://stt:8000")
TTS = os.getenv("TTS_INTERNAL_URL", "http://tts:7860")
QDRANT = os.getenv("QDRANT_INTERNAL_URL", "http://qdrant:6333")
MODEL = os.getenv("OLLAMA_CHAT_MODEL", "qwen3:4b-instruct")
VOICE = os.getenv("TTS_VOICE", "pf_dora")


def get(url: str, timeout: int = 10):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()


def post_json(url: str, payload, timeout: int = 180):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def wait(url: str, attempts: int = 60, delay: int = 2):
    last = None
    for _ in range(attempts):
        try:
            return get(url, timeout=5)
        except Exception as exc:
            last = exc
            time.sleep(delay)
    raise RuntimeError(f"Endpoint não ficou pronto: {url} ({last})")


print("Qdrant...")
wait(QDRANT + "/readyz")

print("STT...")
wait(STT + "/health")

print("TTS...")
wait(TTS + "/tts/status")
audio = post_json(
    TTS + "/tts/generate",
    {"text": "Olá. Eu sou a Maya, secretária da empresa.", "voice": VOICE, "output_format": "wav"},
)
if len(audio) < 1000:
    raise RuntimeError("TTS gerou áudio vazio ou inválido")

print("Ollama...")
wait(OLLAMA + "/api/tags")
last = None
for _ in range(120):
    try:
        raw = post_json(
            OLLAMA + "/api/chat",
            {"model": MODEL, "stream": False, "messages": [{"role": "user", "content": "Responda apenas: ok"}]},
            timeout=180,
        )
        data = json.loads(raw.decode("utf-8"))
        if data.get("message", {}).get("content"):
            last = None
            break
        last = RuntimeError("Ollama respondeu sem conteúdo")
    except Exception as exc:
        last = exc
        time.sleep(3)
else:
    raise RuntimeError(f"Modelo Ollama não ficou pronto: {last}")

print("PASS: IA local e serviços auxiliares responderam na rede Docker interna.")
