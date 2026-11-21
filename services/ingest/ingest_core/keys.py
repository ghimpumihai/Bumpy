"""Device keys: the Key Vault secret holds {"<deviceId>": "<sha256 hex of key>"} (infra/scripts/add-device-key.ps1).

Only hashes are ever loaded. A presented key is hashed and compared against every stored hash in
constant time, so neither the result nor the timing says which device (if any) came close.

Each key is bound to the name it was stored under, which must be the deviceId the app sends (the
app shows it in Settings → Device ID). A key may only send as its own device (`may_send_as`), so
one leaked key can't post batches or session metadata for another phone.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import threading
import time
from typing import Callable, Iterable, Mapping

# Device IDs the replay tool sends: `replay-<the recorded phone's deviceId>` by default.
REPLAY_PREFIX = "replay-"


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def parse_secret(value: str | None) -> dict[str, frozenset[str]]:
    """{sha256 hex: device IDs stored under that hash} from the secret's JSON value; an empty or
    missing secret means no device may send. A hash stored under two names may send as either."""
    if not value:
        return {}
    data = json.loads(value)
    if not isinstance(data, dict):
        raise ValueError("device key secret must be a JSON object of deviceId -> sha256 hex")
    out: dict[str, set[str]] = {}
    for device_id, h in data.items():
        out.setdefault(str(h).lower(), set()).add(device_id)
    return {h: frozenset(ids) for h, ids in out.items()}


def is_replay_key(names: Iterable[str]) -> bool:
    return any(n.lower() == "replay" or n.lower().startswith(REPLAY_PREFIX) for n in names)


def may_send_as(names: Iterable[str], device_id: str) -> bool:
    """Whether a key stored under `names` may send messages with this deviceId:
    - its own name (compared case-insensitively: iOS writes UUIDs in upper case, people type them
      in either);
    - `replay-<own name>`: a phone's key replaying one of its own trips (tools/replay);
    - any `replay-…` ID for a replay key (stored as `replay` or `replay-<something>`), so the replay
      tool can re-send any phone's trip under its own marker without being able to pose as a phone.
    """
    names = [n.lower() for n in names]
    d = device_id.lower()
    if d in names:
        return True
    if d.startswith(REPLAY_PREFIX):
        return is_replay_key(names) or d[len(REPLAY_PREFIX):] in names
    return False


class KeyStore:
    """Caches the hashes. An unknown key triggers a reload at most every `min_reload_s` seconds,
    so a key added with add-device-key.ps1 works within a minute without restarting the app."""

    def __init__(self, loader: Callable[[], Mapping[str, Iterable[str]]], min_reload_s: float = 60.0,
                 clock: Callable[[], float] = time.monotonic):
        self._loader = loader
        self._min_reload_s = min_reload_s
        self._clock = clock
        self._lock = threading.Lock()
        self._entries: tuple[tuple[str, frozenset[str]], ...] | None = None
        self._loaded_at = 0.0

    def _reload(self) -> None:
        loaded = self._loader()  # may raise: the caller answers 503, not 401
        self._entries = tuple((h, frozenset(ids)) for h, ids in loaded.items())
        self._loaded_at = self._clock()

    def _match(self, presented_hash: str) -> frozenset[str] | None:
        found = None
        for h, ids in self._entries or ():  # no early exit: same time for every key
            if hmac.compare_digest(presented_hash, h):
                found = ids
        return found

    def identify(self, presented: str | None) -> frozenset[str] | None:
        """The device IDs the key is stored under, or None for an unknown key."""
        if not presented:
            return None
        presented_hash = hash_key(presented)
        with self._lock:
            if self._entries is None:
                self._reload()
            found = self._match(presented_hash)
            if found is not None:
                return found
            if self._clock() - self._loaded_at >= self._min_reload_s:
                self._reload()
                return self._match(presented_hash)
            return None

    def check(self, presented: str | None) -> bool:
        return self.identify(presented) is not None
