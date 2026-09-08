import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WF = ROOT / "starter" / "workflows"


def load(name: str):
    return json.loads((WF / name).read_text(encoding="utf-8"))


def code_text(workflow):
    return "\n".join(
        node.get("parameters", {}).get("jsCode", "")
        for node in workflow.get("nodes", [])
        if node.get("type") == "n8n-nodes-base.code"
    )


def google_nodes(workflow):
    return [n for n in workflow.get("nodes", []) if n.get("type") == "n8n-nodes-base.googleCalendar"]


def test_calendar_adapters_use_symbolic_google_oauth_credential():
    for name in [
        "04-calendar-availability.json",
        "05-calendar-book.json",
        "08-calendar-reschedule.json",
        "09-calendar-cancel.json",
    ]:
        wf = load(name)
        nodes = google_nodes(wf)
        assert len(nodes) == 1
        cred = nodes[0]["credentials"]["googleCalendarOAuth2Api"]
        assert cred["id"] == "ASSIS_GOOGLE_CALENDAR"
        assert cred["name"] == "Assis Google Calendar"


def test_calendar_write_operations_require_confirmation_and_idempotency_key():
    for name in [
        "05-calendar-book.json",
        "08-calendar-reschedule.json",
        "09-calendar-cancel.json",
    ]:
        code = code_text(load(name))
        assert "explicit confirmation required" in code
        assert "idempotency_key required" in code
        assert "confirmed!==true" in code


def test_calendar_availability_is_read_only():
    wf = load("04-calendar-availability.json")
    google = google_nodes(wf)[0]
    assert google["parameters"]["resource"] == "calendar"
    assert "operation" not in google["parameters"]
    assert "timeMin" in google["parameters"]
    assert "timeMax" in google["parameters"]


def test_calendar_stubs_are_replaced_by_real_provider_nodes():
    for name in [
        "04-calendar-availability.json",
        "05-calendar-book.json",
        "08-calendar-reschedule.json",
        "09-calendar-cancel.json",
    ]:
        text = (WF / name).read_text(encoding="utf-8")
        assert "adapter_required" not in text
        assert "n8n-nodes-base.googleCalendar" in text
