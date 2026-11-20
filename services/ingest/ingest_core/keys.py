"""Device keys: the Key Vault secret holds {"<deviceId>": "<sha256 hex of key>"} (infra/scripts/add-device-key.ps1).

Only hashes are ever loaded. A presented key is hashed and compared against every stored hash in
constant time, so neither the result nor the timing says which device (if any) came close.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import threading
import time
from typing import Callable, Iterable


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def parse_secret(value: str | None) -> list[str]:
    """Hashes from the secret's JSON value; an empty or missing secret means no device may send."""
    if not value:
        return []
    data = json.loads(value)
    if not isinstance(data, dict):
        raise ValueError("device key secret must be a JSON object of deviceId -> sha256 hex")
    return [str(h).lower() for h in data.values()]


class KeyStore:
    """Caches the hashes. An unknown key triggers a reload at most every `min_reload_s` seconds,
    so a key added with add-device-key.ps1 works within a minute without restarting the app."""

    def __init__(self, loader: Callable[[], Iterable[str]], min_reload_s: float = 60.0,
                 clock: Callable[[], float] = time.monotonic):
        self._loader = loader
        self._min_reload_s = min_reload_s
        self._clock = clock
        self._lock = threading.Lock()
        self._hashes: tuple[str, ...] | None = None
        self._loaded_at = 0.0

    def _reload(self) -> None:
        hashes = tuple(self._loader())  # may raise: the caller answers 503, not 401
        self._hashes = hashes
        self._loaded_at = self._clock()

    def _match(self, presented_hash: str) -> bool:
        ok = False
        for h in self._hashes or ():
            ok |= hmac.compare_digest(presented_hash, h)
        return ok

    def check(self, presented: str | None) -> bool:
        if not presented:
            return False
        presented_hash = hash_key(presented)
        with self._lock:
            if self._hashes is None:
                self._reload()
            if self._match(presented_hash):
                return True
            if self._clock() - self._loaded_at >= self._min_reload_s:
                self._reload()
                return self._match(presented_hash)
            return False
