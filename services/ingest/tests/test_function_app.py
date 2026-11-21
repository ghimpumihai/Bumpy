"""The thin Azure wiring: never overwrite an archived blob."""

import importlib
import sys

from azure.core.exceptions import ResourceExistsError

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

    def upload_blob(self, name, data, overwrite, content_settings):
        self.calls.append(overwrite)
        if name in self.blobs and not overwrite:
            raise ResourceExistsError("BlobAlreadyExists")
        self.blobs[name] = data


def test_archive_never_overwrites(monkeypatch):
    fa = _load(monkeypatch)
    sinks = object.__new__(fa.AzureSinks)
    sinks._lake = FakeContainer()
    assert sinks.archive("raw/session=s/00000000.json.gz", b"first") is True
    assert sinks.archive("raw/session=s/00000000.json.gz", b"second") is False
    assert sinks._lake.blobs == {"raw/session=s/00000000.json.gz": b"first"}
    assert sinks._lake.calls == [False, False]
