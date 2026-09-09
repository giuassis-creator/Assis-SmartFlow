import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

app = FastAPI(title="Assis Provider Gateway", version="1.0.0")
logger = logging.getLogger("assis.provider_gateway")

N8N_INTERNAL_URL = os.getenv("N8N_INTERNAL_URL", "http://n8n:5678").rstrip("/")
EVOLUTION_BASE_URL = os.getenv("EVOLUTION_BASE_URL", "").rstrip("/")
EVOLUTION_API_KEY = os.getenv("EVOLUTION_API_KEY", "")
EVOLUTION_INSTANCE = os.getenv("EVOLUTION_INSTANCE", "")
EVOLUTION_SENDTEXT_PAYLOAD_STYLE = os.getenv("EVOLUTION_SENDTEXT_PAYLOAD_STYLE", "modern").strip().lower()


class SendTextRequest(BaseModel):
    to: str = Field(min_length=8, max_length=80)
    text: str = Field(min_length=1, max_length=4096)
    delay_ms: int = Field(default=0, ge=0, le=15000)


def _json_request(url: str, payload: dict, headers: dict[str, str], timeout: float = 30.0):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            body = json.loads(raw) if raw else {}
            return response.status, body
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {"error": raw[:2000]}
        return exc.code, body
    except (urllib.error.URLError, TimeoutError) as exc:
        raise HTTPException(status_code=HTTPStatus.BAD_GATEWAY, detail=f"provider connection failed: {exc}") from exc


def _verify_internal_token(token: str) -> None:
    if not token:
        raise HTTPException(status_code=HTTPStatus.UNAUTHORIZED, detail="missing internal token")
    status, body = _json_request(
        f"{N8N_INTERNAL_URL}/webhook/assis/internal/auth/verify",
        {"token": token, "secret_name": "core-internal-agent"},
        {"Content-Type": "application/json"},
        timeout=15.0,
    )
    if status != HTTPStatus.OK or not isinstance(body, dict) or body.get("valid") is not True:
        raise HTTPException(status_code=HTTPStatus.UNAUTHORIZED, detail="invalid internal token")


def _normalized_number(value: str) -> str:
    value = value.strip()
    if "@" in value:
        value = value.split("@", 1)[0]
    digits = "".join(ch for ch in value if ch.isdigit())
    if len(digits) < 8:
        raise HTTPException(status_code=HTTPStatus.UNPROCESSABLE_ENTITY, detail="invalid destination number")
    return digits


def _provider_payload(number: str, text: str, delay_ms: int, style: str | None = None) -> dict:
    style = (style or EVOLUTION_SENDTEXT_PAYLOAD_STYLE).strip().lower()
    if style == "legacy":
        payload = {"number": number, "textMessage": {"text": text}}
        if delay_ms:
            payload["options"] = {"delay": delay_ms, "presence": "composing"}
        return payload
    if style != "modern":
        raise HTTPException(status_code=HTTPStatus.INTERNAL_SERVER_ERROR, detail="invalid Evolution payload style")
    payload = {"number": number, "text": text}
    if delay_ms:
        payload["delay"] = delay_ms
    return payload


def _body_text(body: object) -> str:
    try:
        return json.dumps(body, ensure_ascii=False).lower()
    except Exception:
        return str(body).lower()


def _looks_like_modern_payload_schema_failure(status: int, body: object) -> bool:
    if status not in {400, 422, 500}:
        return False
    text = _body_text(body)
    # Evolution 2.4 RC builds have returned 500 while trying to read textMessage
    # even when their public DTO accepted {number,text}. This signature indicates
    # validation/shape failure before a message can be sent, so one legacy retry
    # is safe and avoids a blind retry on unrelated 5xx responses.
    return "textmessage" in text and any(token in text for token in ("undefined", "required", "reading", "missing"))


@app.get("/healthz")
def healthz():
    configured = bool(EVOLUTION_BASE_URL and EVOLUTION_API_KEY and EVOLUTION_INSTANCE)
    return {
        "ok": True,
        "evolution_configured": configured,
        "payload_style": EVOLUTION_SENDTEXT_PAYLOAD_STYLE,
    }


@app.post("/v1/evolution/send-text")
def evolution_send_text(
    request: SendTextRequest,
    x_assis_internal_token: str | None = Header(default=None),
):
    _verify_internal_token(x_assis_internal_token or "")
    if not EVOLUTION_BASE_URL or not EVOLUTION_API_KEY or not EVOLUTION_INSTANCE:
        raise HTTPException(status_code=HTTPStatus.SERVICE_UNAVAILABLE, detail="Evolution outbound provider is not configured")

    number = _normalized_number(request.to)
    instance = urllib.parse.quote(EVOLUTION_INSTANCE, safe="")
    endpoint = f"{EVOLUTION_BASE_URL}/message/sendText/{instance}"
    headers = {"Content-Type": "application/json", "apikey": EVOLUTION_API_KEY}
    selected_style = EVOLUTION_SENDTEXT_PAYLOAD_STYLE

    status, body = _json_request(
        endpoint,
        _provider_payload(number, request.text, request.delay_ms, selected_style),
        headers,
        timeout=45.0,
    )

    fallback_used = False
    if selected_style == "modern" and _looks_like_modern_payload_schema_failure(status, body):
        logger.warning(
            "Evolution rejected modern sendText payload with schema signature; retrying once with legacy profile (provider_status=%s response=%s)",
            status,
            json.dumps(body, ensure_ascii=False)[:2000],
        )
        status, body = _json_request(
            endpoint,
            _provider_payload(number, request.text, request.delay_ms, "legacy"),
            headers,
            timeout=45.0,
        )
        fallback_used = True

    if status < 200 or status >= 300:
        logger.error(
            "Evolution sendText failed provider_status=%s payload_style=%s fallback_used=%s response=%s",
            status,
            selected_style,
            fallback_used,
            json.dumps(body, ensure_ascii=False)[:4000],
        )
        raise HTTPException(
            status_code=HTTPStatus.BAD_GATEWAY,
            detail={
                "provider_status": status,
                "provider_response": body,
                "payload_style": selected_style,
                "legacy_fallback_used": fallback_used,
            },
        )

    message_id = None
    if isinstance(body, dict):
        key = body.get("key")
        if isinstance(key, dict):
            message_id = key.get("id")
        message_id = message_id or body.get("id") or body.get("messageId")

    return {
        "provider": "evolution",
        "provider_status": status,
        "provider_message_id": message_id,
        "to": number,
        "payload_style": "legacy" if fallback_used else selected_style,
        "legacy_fallback_used": fallback_used,
        "raw": body,
    }
