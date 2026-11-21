import json

import pytest

from ingest_core.keys import KeyStore, hash_key, may_send_as, parse_secret


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
