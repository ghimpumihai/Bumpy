import json

import pytest

from ingest_core.keys import KeyStore, StaleKeys, hash_key, may_send_as, parse_secret


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def test_parse_secret_maps_hash_to_device():
    assert parse_secret(json.dumps({"phone": "ABC"})) == {"abc": frozenset({"phone"})}
    assert parse_secret(json.dumps({"a": "h1", "b": "H1", "c": "h2"})) == \
        {"h1": frozenset({"a", "b"}), "h2": frozenset({"c"})}
    assert parse_secret("") == {}
    with pytest.raises(ValueError):
        parse_secret("[1, 2]")


def test_known_and_unknown_keys():
    store = KeyStore(lambda: {hash_key("k1"): {"PHONE-1"}})
    assert store.identify("k1") == {"PHONE-1"}
    assert store.check("k1")
    assert store.identify("k2") is None
    assert store.identify("") is None
    assert store.identify(None) is None


def test_new_key_is_picked_up_after_reload_interval():
    stored = {hash_key("old"): {"a"}}
    loads = []

    def loader():
        loads.append(1)
        return dict(stored)

    clock = Clock()
    store = KeyStore(loader, min_reload_s=60, clock=clock)
    assert store.check("old")
    stored[hash_key("new")] = {"b"}

    assert not store.check("new")  # too soon to reload
    assert len(loads) == 1
    clock.t = 61
    assert store.identify("new") == {"b"}
    assert len(loads) == 2


def test_unknown_keys_cannot_hammer_key_vault():
    loads = []
    store = KeyStore(lambda: loads.append(1) or {}, min_reload_s=60, clock=Clock())
    for _ in range(100):
        store.check("guess")
    assert len(loads) == 1


@pytest.mark.parametrize("names, device_id, ok", [
    ({"8C3F1A2B-0000-4000-8000-000000000001"}, "8C3F1A2B-0000-4000-8000-000000000001", True),
    ({"8c3f1a2b-0000-4000-8000-000000000001"}, "8C3F1A2B-0000-4000-8000-000000000001", True),  # typed in lower case
    ({"PHONE-1"}, "PHONE-2", False),
    ({"PHONE-1"}, "replay-PHONE-1", True),   # replaying one of its own trips
    ({"PHONE-1"}, "replay-PHONE-2", False),  # not someone else's
    ({"PHONE-1"}, "PHONE-1-x", False),
    ({"PHONE-1", "PHONE-2"}, "PHONE-2", True),  # one key stored under two names
    ({"replay"}, "replay-PHONE-2", True),     # the replay key: any replay-… ID
    ({"replay-laptop"}, "replay-anything", True),
    ({"replay"}, "PHONE-2", False),           # but never a phone
    ({"replay"}, "replay", True),
    ({"replayer"}, "replay-x", False),
])
def test_may_send_as(names, device_id, ok):
    assert may_send_as(names, device_id) is ok


def test_renamed_key_gets_its_new_binding_on_the_next_mismatch():
    # add-device-key.ps1 -RenameFrom keeps the hash, so a known key must reload when its binding fails.
    stored = {hash_key("k"): {"iphone-mihai"}}
    clock = Clock()
    store = KeyStore(lambda: dict(stored), min_reload_s=60, clock=clock)
    assert store.identify("k") == {"iphone-mihai"}
    stored[hash_key("k")] = {"8C3F1A2B-0000-4000-8000-000000000001"}
    clock.t = 30
    assert store.identify("k", refresh=True) == {"iphone-mihai"}  # rate-limited
    clock.t = 61
    assert store.identify("k", refresh=True) == {"8C3F1A2B-0000-4000-8000-000000000001"}


def test_revoked_key_stops_working_without_a_restart():
    stored = {hash_key("k"): {"PHONE-1"}}
    clock = Clock()
    store = KeyStore(lambda: dict(stored), min_reload_s=60, max_age_s=300, clock=clock)
    assert store.check("k")
    del stored[hash_key("k")]
    clock.t = 299
    assert store.check("k")  # still cached
    clock.t = 301
    assert not store.check("k")


def test_periodic_reload_failure_keeps_the_cached_keys_and_retries_later():
    loads = []
    state = {"fail": False}

    def loader():
        loads.append(1)
        if state["fail"]:
            raise RuntimeError("vault blip")
        return {hash_key("k"): {"PHONE-1"}}

    clock = Clock()
    store = KeyStore(loader, min_reload_s=60, max_age_s=300, clock=clock)
    assert store.check("k")
    state["fail"] = True
    clock.t = 301
    for _ in range(50):
        assert store.identify("k") == {"PHONE-1"}  # served from the cache, no 503
    assert len(loads) == 2  # one failed attempt, not one per request
    state["fail"] = False
    clock.t = 362
    assert store.check("k") and len(loads) == 3


def test_failed_reload_for_an_unknown_key_or_a_mismatch_raises():
    state = {"fail": False}

    def loader():
        if state["fail"]:
            raise RuntimeError("vault down")
        return {hash_key("k"): {"PHONE-1"}}

    clock = Clock()
    store = KeyStore(loader, min_reload_s=60, clock=clock)
    assert store.check("k")
    state["fail"] = True
    clock.t = 61
    with pytest.raises(RuntimeError):  # the handler answers 503, so the app retries
        store.identify("unknown")
    clock.t = 122
    with pytest.raises(RuntimeError):
        store.identify("k", refresh=True)


def test_cached_keys_expire_after_a_long_key_vault_outage():
    """A revoked key keeps working through a Key Vault outage only up to max_stale_s; after that
    every request is refused with an error (503), until Key Vault answers again."""
    state = {"fail": False}

    def loader():
        if state["fail"]:
            raise RuntimeError("vault down")
        return {hash_key("k"): {"PHONE-1"}}

    clock = Clock()
    store = KeyStore(loader, min_reload_s=60, max_age_s=300, max_stale_s=6 * 3600, clock=clock)
    assert store.check("k")
    state["fail"] = True
    clock.t = 6 * 3600  # failing reloads all along: the cached keys still serve
    assert store.check("k")
    clock.t = 6 * 3600 + 1
    with pytest.raises(StaleKeys):
        store.check("k")
    with pytest.raises(StaleKeys):
        store.identify("k", refresh=True)
    clock.t += 61
    with pytest.raises(StaleKeys):  # tried again, still failing
        store.check("k")
    state["fail"] = False
    clock.t += 61
    assert store.check("k")  # Key Vault is back: fresh keys again


def test_default_max_stale_is_generous():
    store = KeyStore(lambda: {})
    assert store._max_stale_s >= 3600  # a Key Vault blip of minutes never stops uploads
