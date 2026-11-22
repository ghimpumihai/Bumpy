"""Device keys: the Key Vault secret holds {"<deviceId>": "<sha256 hex of key>"} (infra/scripts/add-device-key.ps1).

Only hashes are ever loaded. A presented key is hashed and compared against every stored hash in
constant time, so neither the result nor the timing says which device (if any) came close.

Each key is bound to the name it was stored under, which must be the deviceId the app sends (also in
a trip's session.json). A key may only send as its own device (`may_send_as`), so
one leaked key can't post batches or session metadata for another phone.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import threading
import time
from typing import Callable, Iterable, Mapping

log = logging.getLogger("ingest.keys")

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


class StaleKeys(RuntimeError):
    """The cached keys are too old to trust and Key Vault can't be read (503)."""


class KeyStore:
    """Caches the hashes and their device IDs, so the secret isn't read on every request.

    The cache is reloaded:
    - when an unknown key arrives (at most every `min_reload_s`): a key added with
      add-device-key.ps1 works within a minute;
    - when a known key sends as a device it isn't bound to (`identify(..., refresh=True)`, at most
      every `min_reload_s`): a key renamed with `-RenameFrom` keeps its hash, so only a reload can
      see its new name. The app retries 403, so the next retry after the rename gets through;
    - in any case every `max_age_s`, so a revoked key stops working without a restart.
    A reload that fails raises (the caller answers 503 and the app retries), except the periodic one
    for a key that is already known: it keeps the cached keys, so a Key Vault blip doesn't turn every
    phone's batches into 503s, and is tried again after `min_reload_s`. Cached keys older than
    `max_stale_s` are no longer used (StaleKeys, so 503): a key revoked during a long Key Vault
    outage stops working after that long at most, and the app's batches wait on the phone.
    """

    def __init__(self, loader: Callable[[], Mapping[str, Iterable[str]]], min_reload_s: float = 60.0,
                 max_age_s: float = 300.0, max_stale_s: float = 6 * 3600.0,
                 clock: Callable[[], float] = time.monotonic):
        self._loader = loader
        self._min_reload_s = min_reload_s
        self._max_age_s = max_age_s
        self._max_stale_s = max_stale_s
        self._clock = clock
        self._lock = threading.Lock()
        self._entries: tuple[tuple[str, frozenset[str]], ...] | None = None
        self._loaded_at = 0.0  # last successful load
        self._tried_at = 0.0  # last attempt, successful or not

    def _reload(self) -> None:
        self._tried_at = self._clock()
        loaded = self._loader()  # may raise: on the first load the caller answers 503, not 401
        self._entries = tuple((h, frozenset(ids)) for h, ids in loaded.items())
        self._loaded_at = self._clock()

    def _reload_if_older_than(self, age_s: float, keep_on_failure: bool) -> None:
        if self._entries is None:
            self._reload()
            return
        now = self._clock()
        if now - self._loaded_at < age_s or now - self._tried_at < self._min_reload_s:
            return
        if not keep_on_failure:
            self._reload()
            return
        try:
            self._reload()
        except Exception:  # noqa: BLE001 - keep serving the cached keys; tried again after min_reload_s
            log.warning("could not reload device keys; keeping the cached ones", exc_info=True)

    def _match(self, presented_hash: str) -> frozenset[str] | None:
        found = None
        for h, ids in self._entries or ():  # no early exit: same time for every key
            if hmac.compare_digest(presented_hash, h):
                found = ids
        return found

    def identify(self, presented: str | None, refresh: bool = False) -> frozenset[str] | None:
        """The device IDs the key is stored under, or None for an unknown key. `refresh=True` asks for
        a reload first (rate-limited), for a known key whose binding didn't match."""
        if not presented:
            return None
        presented_hash = hash_key(presented)
        with self._lock:
            if refresh:
                self._reload_if_older_than(self._min_reload_s, keep_on_failure=False)
            else:
                self._reload_if_older_than(self._max_age_s, keep_on_failure=True)
            age = self._clock() - self._loaded_at
            if age > self._max_stale_s:
                raise StaleKeys(f"device keys last loaded {age:.0f} s ago (Key Vault failing), "
                                f"more than {self._max_stale_s:.0f} s")
            found = self._match(presented_hash)
            if found is None:
                self._reload_if_older_than(self._min_reload_s, keep_on_failure=False)
                found = self._match(presented_hash)
            return found

    def check(self, presented: str | None) -> bool:
        return self.identify(presented) is not None
