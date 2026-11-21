"""Which device a session belongs to (D53).

The first batch or session.json that passes every other check records its deviceId as the session's
owner, in the `lake` blob `owners/session=<sessionId>.json`, written once and never overwritten. A
later batch or session.json for that session from another deviceId gets 403, before anything is
published or archived, so one valid key can't take another phone's archive blobs first (the archive
keeps the first copy) or add to its trip.

The marker lives outside `raw/session=<id>/`: the finalize job reads every blob under that prefix as
a gzip batch or session copy (processor roadride/finalize.py).

Owners never change, so they are cached per worker; a worker that hasn't seen a session reads the
marker once. Any storage failure raises, and the handler answers 503 so the phone retries.
"""

from __future__ import annotations

import json
import threading
from collections import OrderedDict
from typing import Callable


def blob_name(session_id: str) -> str:
    return f"owners/session={session_id}.json"


def encode(session_id: str, device_id: str, claimed_at_utc: str) -> bytes:
    return json.dumps({"sessionId": session_id, "deviceId": device_id,
                       "claimedAtUtc": claimed_at_utc}).encode("utf-8")


def decode(data: bytes) -> str:
    """The owner's deviceId from a marker. Raises ValueError if it isn't one ingest wrote."""
    doc = json.loads(data)
    if not isinstance(doc, dict) or not isinstance(doc.get("deviceId"), str) or not doc["deviceId"]:
        raise ValueError("session owner marker without a deviceId")
    return doc["deviceId"]


def same_device(a: str, b: str) -> bool:
    return a.lower() == b.lower()  # as keys.may_send_as: iOS writes UUIDs in upper case


class OwnerCache:
    """`claim(session_id, device_id)` records `device_id` as the owner unless one is recorded, and
    returns the recorded owner. Only its answers are cached, never its failures."""

    def __init__(self, claim: Callable[[str, str], str], max_entries: int = 50_000):
        self._claim = claim
        self._max_entries = max_entries
        self._lock = threading.Lock()
        self._owners: OrderedDict[str, str] = OrderedDict()

    def owner(self, session_id: str, device_id: str) -> str:
        with self._lock:
            known = self._owners.get(session_id)
            if known is not None:
                self._owners.move_to_end(session_id)
                return known
        owner = self._claim(session_id, device_id)  # storage call, outside the lock
        with self._lock:
            self._owners[session_id] = owner
            self._owners.move_to_end(session_id)
            while len(self._owners) > self._max_entries:
                self._owners.popitem(last=False)
        return owner
