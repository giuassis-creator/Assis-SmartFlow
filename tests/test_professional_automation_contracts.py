import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / "professional" / "workflows"


def load_workflow(name: str) -> dict:
    return json.loads((WORKFLOWS / name).read_text(encoding="utf-8"))


def node_by_name(workflow: dict, name: str) -> dict:
    return next(node for node in workflow["nodes"] if node["name"] == name)


def test_reminders_schedule_and_policy_are_bounded():
    workflow = load_workflow("12-reminders.json")
    schedule = node_by_name(workflow, "Every 15 Minutes")
    policy = node_by_name(workflow, "Reminder Policy")["parameters"]["jsCode"]

    interval = schedule["parameters"]["rule"]["interval"][0]
    assert interval == {"field": "minutes", "minutesInterval": 15}
    assert "window_minutes:15" in policy
    assert "max_attempts:3" in policy
    assert "quiet_hours:{start:'20:00',end:'08:00'}" in policy


def test_lead_recovery_schedule_and_stop_conditions_are_bounded():
    workflow = load_workflow("13-lead-recovery.json")
    schedule = node_by_name(workflow, "Every 4 Hours")
    policy = node_by_name(workflow, "Recovery Policy")["parameters"]["jsCode"]

    interval = schedule["parameters"]["rule"]["interval"][0]
    assert interval == {"field": "hours", "hoursInterval": 4}
    assert "max_attempts:3" in policy
    assert "min_hours_between_attempts:24" in policy
    for stop_condition in ("reply", "handoff", "opt_out", "closed"):
        assert f"'{stop_condition}'" in policy


def test_documents_webhook_contract_is_stable():
    workflow = load_workflow("14-documents.json")
    webhook = node_by_name(workflow, "Document Intake")

    assert webhook["parameters"]["httpMethod"] == "POST"
    assert webhook["parameters"]["path"] == "professional/documents"
    assert webhook["parameters"]["responseMode"] == "lastNode"


def test_documents_guard_requires_reference_and_allowlisted_extension():
    workflow = load_workflow("14-documents.json")
    guard = node_by_name(workflow, "Document Guard")["parameters"]["jsCode"]

    assert "!b.file_ref" in guard
    assert "!allowed.includes(ext)" in guard
    for extension in ("pdf", "png", "jpg", "jpeg", "doc", "docx", "xlsx", "csv"):
        assert f"'{extension}'" in guard


def test_documents_guard_enforces_security_flags():
    workflow = load_workflow("14-documents.json")
    guard = node_by_name(workflow, "Document Guard")["parameters"]["jsCode"]

    assert "malware_scan_required:true" in guard
    assert "store_private:true" in guard
    assert "extract_after_scan:true" in guard


def test_professional_automation_workflows_have_expected_connections():
    expected = {
        "12-reminders.json": ("Every 15 Minutes", "Reminder Policy"),
        "13-lead-recovery.json": ("Every 4 Hours", "Recovery Policy"),
        "14-documents.json": ("Document Intake", "Document Guard"),
    }
    for filename, (source, target) in expected.items():
        workflow = load_workflow(filename)
        edge = workflow["connections"][source]["main"][0][0]
        assert edge == {"node": target, "type": "main", "index": 0}
