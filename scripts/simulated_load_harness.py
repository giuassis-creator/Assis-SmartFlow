"""Fail-closed lifecycle helpers for the dedicated simulated load project."""
from __future__ import annotations

import re
from typing import Iterable

PRODUCTION_VOLUME = "assis-smartflow_ollama_data"
PRODUCTION_PROJECT_PREFIX = "assis-smartflow"
MARKER = "ASSIS_E2E_SIMULATED"


def validate_isolation(marker: str, project: str, volume: str) -> None:
    if marker != MARKER:
        raise ValueError("ASSIS_E2E_SIMULATED marker is required")
    if not re.fullmatch(r"assis-smartflow-load-[a-z0-9-]+", project):
        raise ValueError("invalid isolated project name")
    if project == PRODUCTION_PROJECT_PREFIX or project.startswith(PRODUCTION_PROJECT_PREFIX + "-") and not project.startswith("assis-smartflow-load-"):
        raise ValueError("project name overlaps production")
    if not re.fullmatch(r"assis-smartflow-load-ollama-[a-z0-9-]+", volume):
        raise ValueError("invalid temporary model volume name")
    if volume == PRODUCTION_VOLUME or volume.startswith(PRODUCTION_PROJECT_PREFIX + "_"):
        raise ValueError("production model volume is forbidden")


def assert_rendered_config_isolated(config: str, project: str, volume: str) -> None:
    validate_isolation(MARKER, project, volume)
    forbidden = (PRODUCTION_VOLUME, "core/docker-compose.yml", "WAHA_BASE_URL", "waha:")
    if any(item in config for item in forbidden):
        raise ValueError("rendered Compose config references production")
    if f"name: {volume}" not in config and f"name: '{volume}'" not in config:
        raise ValueError("model_cache does not point to the requested temporary volume")


def cleanup_targets(resources: Iterable[dict], project: str, volume: str) -> list[str]:
    """Return only explicitly labelled isolated resources; never broad-delete."""
    validate_isolation(MARKER, project, volume)
    allowed = []
    for resource in resources:
        labels = resource.get("labels", {})
        if labels.get("com.docker.compose.project") != project:
            continue
        if resource.get("name") == volume and labels.get("assis.e2e.simulated") != "true":
            continue
        if labels.get("assis.e2e.simulated") == "true":
            allowed.append(resource["name"])
    return allowed
