"""Request handling for both routes, independent of Azure Functions and the Azure SDKs.

Checks run in the same order as the mock server the app was tested against
(mobile/mobile-ios/tools/mock_ingest_server.py):
  1. x-device-key (401), then the body as sent: present (400) and at most contract.MAX_BODY (413)
  2. Content-Type application/json (400)
  3. gunzip when the body starts with the gzip magic bytes, whatever Content-Encoding says: the
     Functions host may inflate the body and drop the header (plan §5). Size caps (413 too large,
     400 broken gzip)
  4. JSON (400)
  5. schema and string limits (400; the app's {"probe": true} lands here: "reachable, key accepted").
     A probe that names its deviceId is checked against the key's binding first (403, step 6)
  6. the body's deviceId must be one the key may send as (403, not in the mock: keys.may_send_as)
  7. x-idempotency-key when present (400)
  8. the session must belong to the body's deviceId (403, not in the mock: owners.py, D53); the first
     message of a session that gets here records its owner
Then the message goes to Event Hubs and the raw archive, and the answer is 200. The function can't
tell a new batch from a retry; repeats are dropped in the database (plan §8), and the archive keeps
the first copy (a repeat finds the blob already there). If Event Hubs or Blob Storage fails (the
owner marker included), the answer is 503 and the app retries the same batch later.
"""

from __future__ import annotations

import datetime as dt
import gzip
import logging
from dataclasses import dataclass, field
from typing import AbstractSet, Mapping, Protocol

from . import contract
from .contract import Invalid, TooLarge
from .keys import may_send_as
from .owners import same_device

log = logging.getLogger("ingest")


@dataclass
class Response:
    status: int
    body: dict
    log_info: str = field(default="", compare=False)


class Sinks(Protocol):
    def publish(self, partition_key: str, body: bytes, properties: dict) -> None:
        """Send one event to Event Hubs; same partition key = same order."""

    def archive(self, blob_name: str, gz_body: bytes) -> bool:
        """Write one blob in the `lake` container unless it already exists. Returns False when it
        existed (a retry of the same message): the first copy is kept, never overwritten."""

    def session_owner(self, session_id: str, device_id: str) -> str:
        """The deviceId the session belongs to: the recorded one, or `device_id`, recorded now
        (never overwritten) if the session has none yet. Raises when storage fails."""


class KeyChecker(Protocol):
    def identify(self, presented: str | None, refresh: bool = False) -> AbstractSet[str] | None:
        """The device IDs the key is bound to, or None for an unknown key. `refresh=True`: reload
        the keys first if allowed (a known key's binding didn't match)."""


def _now_iso(now: dt.datetime) -> str:
    return now.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _error(status: int, reason: str, info: str = "") -> Response:
    return Response(status, {"error": reason}, (info + " " if info else "") + f"reason={reason}")


def _decode(headers: Mapping[str, str], raw: bytes | None, keys: KeyChecker, max_inflated: int):
    """Steps 1-4. Returns (parsed JSON, decompressed bytes, gzip bytes, key's device IDs) or a
    Response."""
    try:
        device_ids = keys.identify(headers.get("x-device-key"))
    except Exception:  # Key Vault unreachable: a server problem, so the app retries
        log.exception("could not load device keys")
        return _error(503, "device keys unavailable, try again later")
    if device_ids is None:
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
        body, was_gzip = contract.decode_body(raw, max_inflated)
    except TooLarge as e:
        return _error(413, str(e))
    except ValueError as e:
        return _error(400, str(e))
    try:
        parsed = contract.parse_json(body)
    except ValueError as e:
        return _error(400, str(e) if was_gzip else contract.not_gzip_reason(str(e)))
    return parsed, body, raw if was_gzip else gzip.compress(body), device_ids


def _not_this_device(device_ids: AbstractSet[str], device_id: str, info: str,
                     headers: Mapping[str, str], keys: KeyChecker) -> Response | None:
    """Step 6: 403 when the key isn't bound to the body's deviceId. The app keeps the message and
    retries 403 with backoff, so nothing is lost while the key's binding is being fixed. A mismatch
    reloads the keys first (rate-limited): a key renamed with `-RenameFrom` keeps its hash, so the
    cached binding would otherwise stay wrong until the app restarts."""
    if may_send_as(device_ids, device_id):
        return None
    try:
        device_ids = keys.identify(headers.get("x-device-key"), refresh=True) or frozenset()
    except Exception:  # Key Vault unreachable: a server problem, so the app retries
        log.exception("could not reload device keys")
        return _error(503, "device keys unavailable, try again later", info)
    if may_send_as(device_ids, device_id):
        return None
    return _error(403, f"deviceId {device_id!r} is not the device this x-device-key was issued to "
                       f"({', '.join(sorted(device_ids))}); store the key under the app's Device ID "
                       "(deviceId in session.json) with infra/scripts/add-device-key.ps1", info)


def _not_the_owner(sinks: Sinks, session_id: str, device_id: str, info: str) -> Response | None:
    """Step 8: 403 when the session belongs to another device (D53), so a valid key can't take
    another phone's archive blobs first or add to its trip. Only a forged message gets here: the
    app records a whole session under one deviceId, and a replay uses a new sessionId."""
    try:
        owner = sinks.session_owner(session_id, device_id)
    except Exception:  # Blob Storage failed: a server problem, so the app retries
        log.exception("could not check the session owner %s", info)
        return _error(503, "could not check the session's device, try again later", info)
    if same_device(owner, device_id):
        return None
    return _error(403, f"session {session_id} belongs to another device: deviceId {device_id!r} "
                       "can't send batches or metadata for it", f"{info} owner={owner}")


def _lower(headers: Mapping[str, str]) -> dict[str, str]:
    return {k.lower(): v for k, v in headers.items()}


def handle_batch(headers: Mapping[str, str], raw: bytes | None, keys: KeyChecker, sinks: Sinks,
                 now: dt.datetime | None = None, max_inflated: int = contract.MAX_INFLATED) -> Response:
    """POST /api/ingest: one 2-second batch."""
    headers = _lower(headers)
    decoded = _decode(headers, raw, keys, max_inflated)
    if isinstance(decoded, Response):
        return decoded
    b, body, gz, device_ids = decoded

    sid = b.get("sessionId") if isinstance(b, dict) else None
    seq = b.get("batchSeq") if isinstance(b, dict) else None
    ids = f"sid={str(sid)[:8] if sid else '-'} seq={seq if seq is not None else '-'}"
    # The app's connectivity probe names its deviceId, so "Test connection" also reports a key
    # stored under another name (403) instead of "key accepted" while every batch gets 403.
    # Probes without one (older app builds) keep the plain 400.
    probe_device = b.get("deviceId") if isinstance(b, dict) and b.get("probe") is True else None
    if isinstance(probe_device, str) and 0 < len(probe_device) <= contract.MAX_ID_LEN:
        forbidden = _not_this_device(device_ids, probe_device, "probe", headers, keys)
        if forbidden:
            return forbidden
    try:
        contract.validate_batch(b)
    except Invalid as e:
        reason = str(e)
        if headers.get("x-probe") == "1" and not reason.startswith(contract.PROBE_PREFIX):
            reason = f"probe request (x-probe: 1) with a non-probe body: {reason}"
        return _error(400, reason, ids)
    forbidden = _not_this_device(device_ids, b["deviceId"], ids, headers, keys)
    if forbidden:
        return forbidden
    idem = headers.get("x-idempotency-key")
    if idem is not None and idem != f"{sid}:{seq}":
        return _error(400, f"x-idempotency-key {idem!r} != '{sid}:{seq}'", ids)
    forbidden = _not_the_owner(sinks, sid, b["deviceId"], ids)
    if forbidden:
        return forbidden

    received = _now_iso(now or dt.datetime.now(dt.timezone.utc))
    properties = {"kind": "batch", "sessionId": sid, "deviceId": b["deviceId"],
                  "batchSeq": seq, "receivedAtUtc": received}
    try:
        sinks.publish(b["deviceId"], body, properties)
        new = sinks.archive(f"raw/session={sid}/{seq:08d}.json.gz", gz)
    except Exception:
        log.exception("forwarding batch failed %s", ids)
        return _error(503, "could not store the batch, try again later", ids)
    return Response(200, {"ok": True, "sessionId": sid, "batchSeq": seq},
                    ids if new else f"{ids} archive=already-there")


def handle_session(path_id: str, headers: Mapping[str, str], raw: bytes | None, keys: KeyChecker,
                   sinks: Sinks, now: dt.datetime | None = None,
                   max_inflated: int = contract.MAX_INFLATED) -> Response:
    """PUT /api/ingest/sessions/{sessionId}: session.json at Start and at Stop."""
    if not contract.SESSION_ID_RE.match(path_id or ""):
        return Response(404, {"message": "Not Found"})
    headers = _lower(headers)
    decoded = _decode(headers, raw, keys, max_inflated)
    if isinstance(decoded, Response):
        return decoded
    m, body, gz, device_ids = decoded

    ids = f"sid={path_id[:8]}"
    try:
        phase = contract.validate_session_meta(m, path_id)
    except Invalid as e:
        return _error(400, str(e), ids)
    forbidden = _not_this_device(device_ids, m["deviceId"], ids, headers, keys)
    if forbidden:
        return forbidden
    idem = headers.get("x-idempotency-key")
    if idem is not None and idem != f"{path_id}:meta-{phase}":
        return _error(400, f"x-idempotency-key {idem!r} != '{path_id}:meta-{phase}' "
                           f"(batchCount {'present' if phase == 'stop' else 'absent'})", ids)
    forbidden = _not_the_owner(sinks, path_id, m["deviceId"], ids)
    if forbidden:
        return forbidden

    # Same partition as the device's batches, so the Stop copy reaches the processor after the
    # trip's last batch (D33).
    device_id = m["deviceId"]
    received = _now_iso(now or dt.datetime.now(dt.timezone.utc))
    properties = {"kind": "session", "sessionId": path_id, "deviceId": device_id,
                  "phase": phase, "receivedAtUtc": received}
    info = f"{ids} phase={phase}"
    try:
        sinks.publish(device_id, body, properties)
        # One blob per phase, so a late retry of the Start copy can never touch the Stop copy.
        new = sinks.archive(f"raw/session={path_id}/session-{phase}.json.gz", gz)
    except Exception:
        log.exception("forwarding session metadata failed %s", info)
        return _error(503, "could not store the session metadata, try again later", info)
    return Response(200, {"ok": True, "sessionId": path_id, "phase": phase},
                    info if new else f"{info} archive=already-there")
