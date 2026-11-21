"""The thin Azure wiring: never overwrite an archived blob, read MAX_BODY_BYTES."""

import importlib
import sys

import pytest
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError

ENV = {
    "EVENTHUB_FULLY_QUALIFIED_NAMESPACE": "ci.servicebus.windows.net",
    "EVENTHUB_NAME": "ingest",
    "STORAGE_BLOB_ENDPOINT": "https://ci.blob.core.windows.net/",
    "KEY_VAULT_URI": "https://ci.vault.azure.net/",
}


def _load(monkeypatch, **env):
    for k, v in {**ENV, **env}.items():
        monkeypatch.setenv(k, v)
    sys.modules.pop("function_app", None)
    return importlib.import_module("function_app")


class FakeContainer:
    def __init__(self):
        self.blobs = {}
        self.calls = []
        self.fail_read = False

    def upload_blob(self, name, data, overwrite, content_settings):
        self.calls.append(overwrite)
        if name in self.blobs and not overwrite:
            raise ResourceExistsError("BlobAlreadyExists")
        self.blobs[name] = data

    def download_blob(self, name):
        if self.fail_read:
            raise RuntimeError("storage down")
        if name not in self.blobs:
            raise ResourceNotFoundError("BlobNotFound")
        data = self.blobs[name]
        return type("Downloader", (), {"readall": lambda self: data})()


def test_archive_never_overwrites(monkeypatch):
    fa = _load(monkeypatch)
    sinks = object.__new__(fa.AzureSinks)
    sinks._lake = FakeContainer()
    assert sinks.archive("raw/session=s/00000000.json.gz", b"first") is True
    assert sinks.archive("raw/session=s/00000000.json.gz", b"second") is False
    assert sinks._lake.blobs == {"raw/session=s/00000000.json.gz": b"first"}
    assert sinks._lake.calls == [False, False]


@pytest.mark.parametrize("setting, limit", [("204800", 204800), ("100000", 100000), ("9999999", 240 * 1024)])
def test_max_body_bytes_is_read(monkeypatch, setting, limit):
    assert _load(monkeypatch, MAX_BODY_BYTES=setting)._MAX_INFLATED == limit


def _sinks(fa):
    sinks = object.__new__(fa.AzureSinks)
    sinks._lake = FakeContainer()
    sinks._owners = fa.owners.OwnerCache(sinks._claim_owner)
    return sinks


def test_first_device_is_recorded_as_owner_and_never_overwritten(monkeypatch):
    fa = _load(monkeypatch)
    sinks = _sinks(fa)
    assert sinks.session_owner("s", "PHONE-1") == "PHONE-1"
    assert set(sinks._lake.blobs) == {"owners/session=s.json"}
    assert sinks._lake.calls == [False]
    # Another worker (empty cache) sees the marker and gets the first device back.
    other = _sinks(fa)
    other._lake = sinks._lake
    assert other.session_owner("s", "PHONE-2") == "PHONE-1"
    assert fa.owners.decode(sinks._lake.blobs["owners/session=s.json"]) == "PHONE-1"


def test_owner_is_cached_per_worker(monkeypatch):
    fa = _load(monkeypatch)
    sinks = _sinks(fa)
    sinks.session_owner("s", "PHONE-1")
    sinks._lake.fail_read = True
    sinks._lake.blobs.clear()  # a storage call would now record PHONE-2
    assert sinks.session_owner("s", "PHONE-2") == "PHONE-1"


def test_unreadable_or_broken_marker_raises(monkeypatch):
    fa = _load(monkeypatch)
    sinks = _sinks(fa)
    sinks._lake.blobs["owners/session=s.json"] = b"{}"
    with pytest.raises(ValueError):
        sinks.session_owner("s", "PHONE-1")
    sinks._lake.blobs["owners/session=t.json"] = b'{"deviceId": "PHONE-1"}'
    sinks._lake.fail_read = True
    with pytest.raises(RuntimeError):
        sinks.session_owner("t", "PHONE-1")
    assert sinks._lake.blobs["owners/session=s.json"] == b"{}"  # never overwritten
