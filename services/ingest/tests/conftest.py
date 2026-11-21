import copy
import gzip
import importlib.util
import json
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SERVICE = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE))

FIXTURE = ROOT / "src" / "mobile-ios" / "tools" / "fixtures" / "ingest_batch_v1.json.gz"
MOCK = ROOT / "src" / "mobile-ios" / "tools" / "mock_ingest_server.py"

DEVICE_KEY = "test-device-key"
DEVICE_ID = "FIXTURE-DEVICE"  # the deviceId in the app-encoded fixture batch
OTHER_KEY = "other-device-key"  # a valid key, bound to another phone
REPLAY_KEY = "replay-key"


@pytest.fixture(scope="session")
def mock_server():
    spec = importlib.util.spec_from_file_location("mock_ingest_server", MOCK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="session")
def _fixture_batch():
    return json.loads(gzip.decompress(FIXTURE.read_bytes()))


@pytest.fixture
def batch(_fixture_batch):
    return copy.deepcopy(_fixture_batch)


@pytest.fixture
def session_meta(batch):
    return {
        "sessionId": batch["sessionId"],
        "deviceId": batch["deviceId"],
        "startedAtUtc": "2026-11-21T09:15:30.000Z",
        "startUptimeSec": 1234.5,
        "endedAtUtc": None,
        "recovered": False,
        "vehicle": {"type": "car"},
        "mount": {"rigid": True},
        "people": {"raterSeat": "front"},
        "audioEnabled": False,
    }


class FakeSinks:
    def __init__(self, fail=False):
        self.events = []
        self.blobs = {}
        self.fail = fail

    def publish(self, partition_key, body, properties):
        if self.fail:
            raise RuntimeError("event hubs down")
        self.events.append((partition_key, body, properties))

    def archive(self, blob_name, gz_body):
        if self.fail:
            raise RuntimeError("storage down")
        if blob_name in self.blobs:  # overwrite=False: the first copy stays
            return False
        self.blobs[blob_name] = gz_body
        return True


@pytest.fixture
def sinks():
    return FakeSinks()


@pytest.fixture
def keys():
    from ingest_core.keys import KeyStore, hash_key, parse_secret
    secret = json.dumps({DEVICE_ID: hash_key(DEVICE_KEY), "OTHER-PHONE": hash_key(OTHER_KEY),
                         "replay": hash_key(REPLAY_KEY)})
    return KeyStore(lambda: parse_secret(secret))


def gz(obj) -> bytes:
    return gzip.compress(json.dumps(obj).encode())


def headers(**extra):
    h = {"x-device-key": DEVICE_KEY, "Content-Encoding": "gzip", "Content-Type": "application/json"}
    h.update(extra)
    return h
