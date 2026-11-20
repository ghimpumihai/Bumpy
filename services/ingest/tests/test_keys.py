import json

import pytest

from ingest_core.keys import KeyStore, hash_key, parse_secret


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def test_parse_secret():
    assert parse_secret(json.dumps({"phone": "ABC"})) == ["abc"]
    assert parse_secret("") == []
    with pytest.raises(ValueError):
        parse_secret("[1, 2]")


def test_known_and_unknown_keys():
    store = KeyStore(lambda: [hash_key("k1")])
    assert store.check("k1")
    assert not store.check("k2")
    assert not store.check("")
    assert not store.check(None)


def test_new_key_is_picked_up_after_reload_interval():
    stored = [hash_key("old")]
    loads = []

    def loader():
        loads.append(1)
        return list(stored)

    clock = Clock()
    store = KeyStore(loader, min_reload_s=60, clock=clock)
    assert store.check("old")
    stored.append(hash_key("new"))

    assert not store.check("new")  # too soon to reload
    assert len(loads) == 1
    clock.t = 61
    assert store.check("new")
    assert len(loads) == 2


def test_unknown_keys_cannot_hammer_key_vault():
    loads = []
    store = KeyStore(lambda: loads.append(1) or [], min_reload_s=60, clock=Clock())
    for _ in range(100):
        store.check("guess")
    assert len(loads) == 1
