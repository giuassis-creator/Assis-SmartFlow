import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

PROTECTED = {
    "library/workflows/01-canonical-ingress.json": "assis/v1/message",
    "library/workflows/02-context-load.json": "internal/context",
    "library/workflows/03-memory-write.json": "internal/memory/write",
    "library/workflows/06-rag-ingest.json": "internal/rag/ingest",
    "library/workflows/07-rag-search.json": "internal/rag/search",
}


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding="utf-8"))


def node_by_name(workflow, name):
    return next(node for node in workflow["nodes"] if node["name"] == name)


def test_protected_internal_workflows_verify_central_auth_before_business_logic():
    for rel, path in PROTECTED.items():
        workflow = load(rel)
        webhook = next(n for n in workflow["nodes"] if n["type"] == "n8n-nodes-base.webhook")
        assert webhook["parameters"]["path"] == path

        code = "\n".join(
            n.get("parameters", {}).get("jsCode", "")
            for n in workflow["nodes"]
            if n["type"] == "n8n-nodes-base.code"
        )
        assert "x-assis-internal-token" in code
        assert "unauthorized" in code
        assert "assis/internal/auth/verify" in code

        verify_nodes = [
            n for n in workflow["nodes"]
            if n["type"] == "n8n-nodes-base.httpRequest"
            and "auth" in n["name"].lower()
        ]
        assert verify_nodes, f"{rel} has no central auth verifier call"
        assert any(
            "auth_endpoint" in n["parameters"].get("url", "")
            for n in verify_nodes
        )


def test_canonical_ingress_is_not_exposed_through_public_proxy():
    caddy = (ROOT / "core/proxy/Caddyfile").read_text(encoding="utf-8")
    assert "/webhook/assis/v1/message" in caddy
    assert "respond @internal_webhooks 404" in caddy


def test_agent_runtime_propagates_internal_token_to_context_rag_and_memory():
    workflow = load("library/agents/00-agent-runtime.json")
    for name in (
        "Load Conversation Context",
        "Retrieve RAG Context",
        "Persist Conversation Memory",
    ):
        node = node_by_name(workflow, name)
        params = node["parameters"]
        assert params.get("sendHeaders") is True, name
        headers = params.get("headerParameters", {}).get("parameters", [])
        assert any(
            h.get("name") == "x-assis-internal-token"
            and "internal_token" in h.get("value", "")
            for h in headers
        ), name


def test_selective_import_support_prevents_unrelated_workflow_deactivation():
    script = (ROOT / "scripts/windows/import-workflows.ps1").read_text(encoding="utf-8")
    assert "[string[]]$Only" in script
    assert "Importação seletiva" in script
    assert "workflows não selecionados permaneceram inalterados" in script

    core_deploy = (ROOT / "scripts/windows/deploy-core-runtime.ps1").read_text(encoding="utf-8")
    calendar_deploy = (ROOT / "scripts/windows/deploy-google-calendar.ps1").read_text(encoding="utf-8")
    assert "-Only $coreImportPaths" in core_deploy
    assert "-Only $calendarImportPaths" in calendar_deploy
