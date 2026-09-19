import json
import os
import urllib.request
import uuid

STT = os.getenv("STT_INTERNAL_URL", "http://stt:8000")
TTS = os.getenv("TTS_INTERNAL_URL", "http://tts:7860")
VOICE = os.getenv("TTS_VOICE", "pf_dora")
TEXT = "Teste local de voz da Assis SmartFlow."


def request_json(url, payload, timeout=180):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read(), dict(response.headers)


def multipart(url, field, filename, body, timeout=180):
    boundary = "----assis-" + uuid.uuid4().hex
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
        "Content-Type: audio/wav\r\n\r\n"
    ).encode()
    data = head + body + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def get(url, timeout=30):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read()


def main():
    get(STT + "/health")
    get(TTS + "/tts/status")
    audio, headers = request_json(
        TTS + "/tts/generate",
        {"text": TEXT, "voice": VOICE, "output_format": "wav"},
    )
    content_type = headers.get("Content-Type", "")
    if len(audio) < 1000 or "audio" not in content_type.lower():
        raise RuntimeError("TTS não produziu WAV válido")
    result = json.loads(multipart(STT + "/v1/transcribe?language=pt", "file", "synthetic-tts.wav", audio))
    if not isinstance(result.get("text"), str):
        raise RuntimeError("STT não retornou campo text")
    print(json.dumps({
        "tts_bytes": len(audio),
        "stt_text": result["text"],
        "stt_language": result.get("language"),
        "provider": "local",
    }, ensure_ascii=False))
    print("PASS: smoke local STT/TTS")


if __name__ == "__main__":
    main()
