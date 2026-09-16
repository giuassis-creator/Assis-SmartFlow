import json
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen

import pytest


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path in ("/api/embed", "/api/embeddings"):
            payload = json.loads(body.decode())
            result = {"keep_alive": payload.get("keep_alive"), "content_type": self.headers.get("Content-Type"), "body_size": len(body)}
            data = json.dumps(result).encode()
            self.send_response(200)
        elif self.path == "/api/chat":
            data = body
            self.send_response(200)
        else:
            self.send_response(500)
            data = b"upstream failure"
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


@pytest.mark.skipif(shutil.which("node") is None, reason="node unavailable")
def test_proxy_integration_mutates_only_embeddings_and_preserves_failures():
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    proxy_port = upstream.server_port + 1
    env = {"OLLAMA_PROXY_TARGET": f"http://127.0.0.1:{upstream.server_port}", "OLLAMA_PROXY_PORT": str(proxy_port)}
    import os
    child_env = os.environ.copy(); child_env.update(env)
    proc = subprocess.Popen(["node", str(Path(__file__).parents[1] / "scripts" / "ollama_embed_proxy.js")], env=child_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                req = Request(f"http://127.0.0.1:{proxy_port}/api/embed", data=b'{"model":"nomic-embed-text","input":["x"]}', headers={"Content-Type": "application/json"})
                with urlopen(req, timeout=1) as response:
                    result = json.loads(response.read())
                assert result["keep_alive"] == 0
                break
            except Exception:
                time.sleep(0.05)
        else:
            raise AssertionError("proxy did not become ready")
        req = Request(f"http://127.0.0.1:{proxy_port}/api/chat", data=b'{"model":"qwen","messages":[]}', headers={"Content-Type": "application/json", "Connection": "close"})
        with urlopen(req) as response:
            assert response.read() == b'{"model":"qwen","messages":[]}'
        req = Request(f"http://127.0.0.1:{proxy_port}/api/embed", data=b"not-json", headers={"Content-Type": "application/json"})
        with pytest.raises(Exception):
            urlopen(req)
    finally:
        proc.terminate(); proc.wait(timeout=5)
        upstream.shutdown(); upstream.server_close()
