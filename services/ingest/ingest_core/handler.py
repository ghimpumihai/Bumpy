"""Request handling for both routes, independent of Azure Functions and the Azure SDKs.

Checks run in the same order as the mock server the app was tested against
(src/mobile-ios/tools/mock_ingest_server.py):
  1. x-device-key (401)
  2. Content-Type application/json (400)
  3. gunzip when the body starts with the gzip magic bytes, whatever Content-Encoding says: the
     Functions host may inflate the body and drop the header (plan §5). Size caps (413 too large,
     400 broken gzip)
  4. JSON (400)
  5. schema and string limits (400; the app's {"probe": true} lands here: "reachable, key accepted")
  6. x-idempotency-key when present (400)
Then the message goes to Event Hubs and the raw archive, and the answer is 200. The function can't
tell a new batch from a retry; repeats are dropped in the database (plan §8). If Event Hubs or Blob
Storage fails, the answer is 503 and the app retries the same batch later.
"""

from __future__ import annotations

import datetime as dt
import gzip
import logging
from dataclasses import dataclass, field
from typing import Mapping, Protocol

from . import contract
from .contract import Invalid, TooLarge

log = logging.getLogger("ingest")


@dataclass
class Response:
    status: int
    body: dict
    log_info: str = field(default="", compare=False)


class Sinks(Protocol):
    def publish(self, partition_key: str, body: bytes, properties: dict) -> None:
        """Send one event to Event Hubs; same partition key = same order."""

    def archive(self, blob_name: str, gz_body: bytes) -> None:
        """Write (or overwrite) one blob in the `lake` container."""


class KeyChecker(Protocol):
    def check(self, presented: str | None) -> bool: ...


def _now_iso(now: dt.datetime) -> str:
    return now.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _error(status: int, reason: str, info: str = "") -> Response:
    return Response(status, {"error": reason}, (info + " " if info else "") + f"reason={reason}")


def _decode(headers: Mapping[str, str], raw: bytes | None, keys: KeyChecker):
    """Steps 1-4. Returns (parsed JSON, decompressed bytes, gzip bytes) or a Response."""
    try:
        key_ok = keys.check(headers.get("x-device-key"))
    except Exception:  # Key Vault unreachable: a server problem, so the app retries
        log.exception("could not load device keys")
        return _error(503, "device keys unavailable, try again later")
    if not key_ok:
        return _error(401, "bad x-device-key")
    if raw is None:
        return _error(400, "missing/invalid Content-Length")
    if len(raw) > contract.MAX_BODY:
        return _error(413, f"body larger than {contract.MAX_BODY} bytes")
    if not (headers.get("content-type") or "").lower().startswith("application/json"):
        return _error(400, "Content-Type must be application/json")
    # The Functions host doesn't document whether it inflates gzip bodies itself, or whether it
    # then drops Content-Encoding (plan §5), so the magic bytes decide, not the header.
    try:
        body, was_gzip = contract.decode_body(raw)
    except TooLarge as e:
        return _error(413, str(e))
    except ValueError as e:
        return _error(400, str(e))
    try:
        parsed = contract.parse_json(body)
    except ValueError as e:
        return _error(400, str(e) if was_gzip else contract.not_gzip_reason(str(e)))
    return parsed, body, raw if was_gzip else gzip.compress(body)


def _lower(headers: Mapping[str, str]) -> dict[str, str]:
    return {k.lower(): v for k, v in headers.items()}


def handle_batch(headers: Mapping[str, str], raw: bytes | None, keys: KeyChecker, sinks: Sinks,
                 now: dt.datetime | None = None) -> Response:
    """POST /api/ingest: one 2-second batch."""
    headers = _lower(headers)
    decoded = _decode(headers, raw, keys)
    if isinstance(decoded, Response):
        return decoded
    b, body, gz = decoded

    sid = b.get("sessionId") if isinstance(b, dict) else None
    seq = b.get("batchSeq") if isinstance(b, dict) else None
    ids = f"sid={str(sid)[:8] if sid else '-'} seq={seq if seq is not None else '-'}"
    try:
        contract.validate_batch(b)
    except Invalid as e:
        reason = str(e)
        if headers.get("x-probe") == "1" and not reason.startswith(contract.PROBE_PREFIX):
            reason = f"probe request (x-probe: 1) with a non-probe body: {reason}"
        return _error(400, reason, ids)
    idem = headers.get("x-idempotency-key")
    if idem is not None and idem != f"{sid}:{seq}":
        return _error(400, f"x-idempotency-key {idem!r} != '{sid}:{seq}'", ids)

    received = _now_iso(now or dt.datetime.now(dt.timezone.utc))
    properties = {"kind": "batch", "sessionId": sid, "deviceId": b["deviceId"],
                  "batchSeq": seq, "receivedAtUtc": received}
    try:
        sinks.publish(b["deviceId"], body, properties)
        sinks.archive(f"raw/session={sid}/{seq:08d}.json.gz", gz)
    except Exception:
        log.exception("forwarding batch failed %s", ids)
        return _error(503, "could not store the batch, try again later", ids)
    return Response(200, {"ok": True, "sessionId": sid, "batchSeq": seq}, ids)


def handle_session(path_id: str, headers: Mapping[str, str], raw: bytes | None, keys: KeyChecker,
                   sinks: Sinks, now: dt.datetime | None = None) -> Response:
    """PUT /api/ingest/sessions/{sessionId}: session.json at Start and at Stop."""
    if not contract.SESSION_ID_RE.match(path_id or ""):
        return Response(404, {"message": "Not Found"})
    headers = _lower(headers)
    decoded = _decode(headers, raw, keys)
    if isinstance(decoded, Response):
        return decoded
    m, body, gz = decoded

    ids = f"sid={path_id[:8]}"
    try:
        phase = contract.validate_session_meta(m, path_id)
    except Invalid as e:
        return _error(400, str(e), ids)
    idem = headers.get("x-idempotency-key")
    if idem is not None and idem != f"{path_id}:meta-{phase}":
        return _error(400, f"x-idempotency-key {idem!r} != '{path_id}:meta-{phase}' "
                           f"(batchCount {'present' if phase == 'stop' else 'absent'})", ids)

    # Same partition as the device's batches, so the Stop copy reaches the processor after the
    # trip's last batch (D33).
    device_id = m["deviceId"]
    received = _now_iso(now or dt.datetime.now(dt.timezone.utc))
    properties = {"kind": "session", "sessionId": path_id, "deviceId": device_id,
                  "phase": phase, "receivedAtUtc": received}
    info = f"{ids} phase={phase}"
    try:
        sinks.publish(device_id, body, properties)
        # One blob per phase, so a late retry of the Start copy can never overwrite the Stop copy.
        sinks.archive(f"raw/session={path_id}/session-{phase}.json.gz", gz)
    except Exception:
        log.exception("forwarding session metadata failed %s", info)
        return _error(503, "could not store the session metadata, try again later", info)
    return Response(200, {"ok": True, "sessionId": path_id, "phase": phase}, info)
