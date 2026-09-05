import json
import os
import time
import urllib.error
import urllib.request

BASE = os.getenv("QDRANT_INTERNAL_URL", "http://qdrant:6333")
COLLECTION = os.getenv("QDRANT_COLLECTION", "assis_knowledge")
DIM = int(os.getenv("EMBEDDING_DIM", "768"))


def request(path: str, method: str = "GET", body=None, timeout: int = 10):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


for attempt in range(60):
    try:
        request("/readyz", timeout=3)
        break
    except Exception:
        if attempt == 59:
            raise RuntimeError("Qdrant não ficou pronto na rede interna Docker")
        time.sleep(2)

try:
    request(f"/collections/{COLLECTION}", timeout=5)
    print(f"Qdrant collection '{COLLECTION}' já existe.")
except urllib.error.HTTPError as exc:
    if exc.code != 404:
        raise
    request(
        f"/collections/{COLLECTION}",
        method="PUT",
        body={"vectors": {"size": DIM, "distance": "Cosine"}},
        timeout=30,
    )
    print(f"Qdrant collection '{COLLECTION}' criada com dimensão {DIM}.")
