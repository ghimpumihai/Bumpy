"""The session-owner cache and marker format (D53)."""

import pathlib

import pytest

from ingest_core import owners


def test_cache_claims_once_per_session():
    calls = []

    def claim(sid, dev):
        calls.append((sid, dev))
        return {"s1": "PHONE-1"}.get(sid, dev)

    cache = owners.OwnerCache(claim)
    assert cache.owner("s1", "PHONE-2") == "PHONE-1"
    assert cache.owner("s1", "PHONE-2") == "PHONE-1"
    assert cache.owner("s2", "PHONE-2") == "PHONE-2"
    assert calls == [("s1", "PHONE-2"), ("s2", "PHONE-2")]


def test_failures_are_not_cached():
    state = {"fail": True}

    def claim(sid, dev):
        if state["fail"]:
            raise RuntimeError("storage down")
        return dev

    cache = owners.OwnerCache(claim)
    with pytest.raises(RuntimeError):
        cache.owner("s", "PHONE-1")
    state["fail"] = False
    assert cache.owner("s", "PHONE-1") == "PHONE-1"


def test_cache_is_bounded_and_evicts_the_least_recent():
    calls = []
    cache = owners.OwnerCache(lambda sid, dev: calls.append(sid) or dev, max_entries=2)
    cache.owner("a", "P")
    cache.owner("b", "P")
    cache.owner("a", "P")  # a is now the most recent
    cache.owner("c", "P")  # evicts b
    cache.owner("a", "P")
    cache.owner("b", "P")
    assert calls == ["a", "b", "c", "b"]


def test_marker_round_trip_and_bad_markers():
    data = owners.encode("s", "PHONE-1", "2026-11-21T09:15:32.120Z")
    assert owners.decode(data) == "PHONE-1"
    for bad in (b"{}", b'{"deviceId": ""}', b"[]", b"not json"):
        with pytest.raises(ValueError):
            owners.decode(bad)


def test_marker_is_outside_the_raw_session_prefix():
    # finalize.BlobArchive.list_names reads every blob under raw/session=<id>/ as a gzip batch
    # or session copy; a JSON marker there would break the trip's finalize.
    name = owners.blob_name("00000000-0000-4000-8000-000000000001")
    assert name == "owners/session=00000000-0000-4000-8000-000000000001.json"
    assert not name.startswith("raw/")


def test_ingest_identity_may_create_and_read_blobs_in_lake():
    """The marker is written (create) and read back (existing marker) in `lake`. Storage Blob Data
    Contributor on the lake container covers both; Blob Data Reader or a write-only role wouldn't."""
    rbac = (pathlib.Path(__file__).resolve().parents[3] / "infra" / "main" / "rbac.tf").read_text()
    line = next(x for x in rbac.splitlines() if x.strip().startswith("ingest_lake_write"))
    assert "module.storage.lake_container_id" in line
    assert '"Storage Blob Data Contributor"' in line
    assert 'local.id["ingest"]' in line
