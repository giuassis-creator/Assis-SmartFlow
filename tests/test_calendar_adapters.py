import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WF = ROOT / "starter" / "workflows"

CALENDAR_FILES = [
    "04-calendar-availability.json",
    "05-calendar-book.json",
    "08-calendar-reschedule.json",
    "09-calendar-cancel.json",
]
WRITE_FILES = [
    "05-calendar-book.json",
    "08-calendar-reschedule.json",
    "09-calendar-cancel.json",
]


def load(name: str):
    return json.loads((WF / name).read_text(encoding="utf-8"))


def code_text(workflow):
    return "\n".join(
        node.get("parameters", {}).get("jsCode", "")
        for node in workflow.get("nodes", [])
        if node.get("type") == "n8n-nodes-base.code"
    )


def nodes_of_type(workflow, node_type):
    return [n for n in workflow.get("nodes", []) if n.get("type") == node_type]


def google_nodes(workflow):
    return nodes_of_type(workflow, "n8n-nodes-base.googleCalendar")


def test_calendar_adapters_use_symbolic_google_oauth_credential():
    for name in CALENDAR_FILES:
        nodes = google_nodes(load(name))
        assert len(nodes) == 1
        cred = nodes[0]["credentials"]["googleCalendarOAuth2Api"]
        assert cred["id"] == "ASSIS_GOOGLE_CALENDAR"
        assert cred["name"] == "Assis Google Calendar"


def test_calendar_webhooks_are_internal_only():
    for name in CALENDAR_FILES:
        wf = load(name)
        webhook = nodes_of_type(wf, "n8n-nodes-base.webhook")[0]
        path = webhook["parameters"]["path"]
        assert path.startswith("assis/internal/calendar/")
        assert "mcp/calendar/" not in path


def test_calendar_adapters_verify_internal_auth():
    for name in CALENDAR_FILES:
        wf = load(name)
        code = code_text(wf)
        assert "x-assis-internal-token" in code
        assert "unauthorized internal calendar call" in code
        http_nodes = nodes_of_type(wf, "n8n-nodes-base.httpRequest")
        assert any("auth_endpoint" in n.get("parameters", {}).get("url", "") for n in http_nodes)


def test_calendar_write_operations_require_confirmation_and_idempotency_key():
    for name in WRITE_FILES:
        code = code_text(load(name))
        assert "explicit confirmation required" in code
        assert "idempotency_key required" in code
        assert "confirmed!==true" in code
        assert "duplicate idempotency key" in code


def test_calendar_writes_have_persistent_idempotency_nodes():
    for name in WRITE_FILES:
        wf = load(name)
        postgres = nodes_of_type(wf, "n8n-nodes-base.postgres")
        assert len(postgres) >= 2
        text = json.dumps(wf)
        assert "tool_idempotency" in text
        assert "ON CONFLICT DO NOTHING" in text
        assert "ASSIS_POSTGRES" in text
        assert "status='completed'" in text


def test_calendar_availability_is_read_only():
    wf = load("04-calendar-availability.json")
    google = google_nodes(wf)[0]
    assert google["parameters"]["resource"] == "calendar"
    assert "operation" not in google["parameters"]
    assert "timeMin" in google["parameters"]
    assert "timeMax" in google["parameters"]
    assert not nodes_of_type(wf, "n8n-nodes-base.postgres")


def test_calendar_stubs_are_replaced_by_real_provider_nodes():
    for name in CALENDAR_FILES:
        text = (WF / name).read_text(encoding="utf-8")
        assert "adapter_required" not in text
        assert "n8n-nodes-base.googleCalendar" in text


def test_tool_policy_gateway_routes_calendar_only_to_internal_paths():
    gateway = json.loads((ROOT / "library" / "agents" / "09-tool-policy-gateway.json").read_text(encoding="utf-8"))
    text = json.dumps(gateway)
    assert "webhook/assis/internal/calendar/availability" in text
    assert "webhook/assis/internal/calendar/book" in text
    assert "webhook/assis/internal/calendar/reschedule" in text
    assert "webhook/assis/internal/calendar/cancel" in text
    assert "webhook/mcp/calendar/" not in text
