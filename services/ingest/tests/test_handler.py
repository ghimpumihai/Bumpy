import gzip
import json

import pytest

from conftest import DEVICE_KEY, OTHER_KEY, REPLAY_KEY, FakeSinks, gz, headers
from ingest_core import contract
from ingest_core.handler import handle_batch, handle_session
from ingest_core.keys import KeyStore


# --- POST /api/ingest -------------------------------------------------------------------

def test_valid_batch_is_published_and_archived(batch, keys, sinks):
    raw = gz(batch)
    resp = handle_batch(headers(**{"x-idempotency-key": f"{batch['sessionId']}:{batch['batchSeq']}"}),
                        raw, keys, sinks)
    assert resp.status == 200
    assert resp.body == {"ok": True, "sessionId": batch["sessionId"], "batchSeq": batch["batchSeq"]}

    (pk, body, props), = sinks.events
    assert pk == batch["deviceId"]
    assert json.loads(body) == batch
    assert props["kind"] == "batch" and props["batchSeq"] == batch["batchSeq"]
    assert props["receivedAtUtc"].endswith("Z")

    name = f"raw/session={batch['sessionId']}/{batch['batchSeq']:08d}.json.gz"
    assert sinks.blobs == {name: raw}  # archived exactly as the phone sent it


def test_retry_finds_its_blob_and_answers_200(batch, keys, sinks):
    first = gz(batch)
    assert handle_batch(headers(), first, keys, sinks).status == 200
    resp = handle_batch(headers(), gz(batch), keys, sinks)
    assert resp.status == 200 and "archive=already-there" in resp.log_info
    assert len(sinks.blobs) == 1
    assert len(sinks.events) == 2  # duplicates are dropped in the database, not here


def test_a_different_body_never_overwrites_the_archive(batch, keys, sinks):
    first = gz(batch)
    assert handle_batch(headers(), first, keys, sinks).status == 200
    batch["labels"] = []
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 200
    (blob,) = sinks.blobs.values()
    assert blob == first  # first copy wins, as ON CONFLICT DO NOTHING in the database


def test_wrong_or_missing_key_is_401_before_anything_else(batch, keys, sinks):
    assert handle_batch(headers(**{"x-device-key": "nope"}), b"not even gzip", keys, sinks).status == 401
    h = headers()
    del h["x-device-key"]
    assert handle_batch(h, gz(batch), keys, sinks).status == 401
    assert not sinks.events


def test_headers_are_case_insensitive(batch, keys, sinks):
    h = {"X-Device-Key": DEVICE_KEY, "content-encoding": "gzip", "CONTENT-TYPE": "application/json"}
    assert handle_batch(h, gz(batch), keys, sinks).status == 200


def test_probe_answers_400_reachable_key_accepted(keys, sinks):
    resp = handle_batch(headers(**{"x-probe": "1"}), gz({"probe": True}), keys, sinks)
    assert resp.status == 400
    assert resp.body["error"].startswith("probe request")
    assert not sinks.events and not sinks.blobs


def test_probe_header_with_bad_body_names_the_probe(batch, keys, sinks):
    batch.pop("labels")
    resp = handle_batch(headers(**{"x-probe": "1"}), gz(batch), keys, sinks)
    assert resp.status == 400
    assert resp.body["error"].startswith("probe request (x-probe: 1) with a non-probe body")


def test_wrong_content_type(batch, keys, sinks):
    assert handle_batch(headers(**{"Content-Type": "text/plain"}), gz(batch), keys, sinks).status == 400


@pytest.mark.parametrize("enc", ["gzip", "x-gzip", "identity", None])
def test_gzip_is_decided_by_magic_bytes_not_content_encoding(enc, batch, keys, sinks):
    h = headers(**{"Content-Encoding": enc})
    if enc is None:
        del h["Content-Encoding"]
    assert handle_batch(h, gz(batch), keys, sinks).status == 200


@pytest.mark.parametrize("keep_header", [True, False])
def test_body_already_inflated_by_host_is_accepted(keep_header, batch, keys, sinks):
    """The host may inflate the body and keep or drop Content-Encoding (plan §5)."""
    h = headers()
    if not keep_header:
        del h["Content-Encoding"]
    raw = json.dumps(batch).encode()
    assert handle_batch(h, raw, keys, sinks).status == 200
    (blob,) = sinks.blobs.values()
    assert json.loads(gzip.decompress(blob)) == batch


def test_body_neither_gzip_nor_json_is_400(keys, sinks):
    resp = handle_batch(headers(**{"Content-Encoding": "br"}), b"\x8b\x0b\x80binary", keys, sinks)
    assert resp.status == 400
    assert resp.body["error"].startswith("body is neither gzip")


def test_too_large_is_413(batch, keys, sinks):
    batch["padding"] = "x" * (contract.MAX_INFLATED + 1)
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 413
    assert handle_batch(headers(), json.dumps(batch).encode(), keys, sinks).status == 413


def test_lower_limit_from_the_setting(batch, keys, sinks):
    size = len(json.dumps(batch).encode())
    assert handle_batch(headers(), gz(batch), keys, sinks, max_inflated=size - 1).status == 413
    assert handle_batch(headers(), gz(batch), keys, sinks, max_inflated=size).status == 200


@pytest.mark.parametrize("setting, limit", [
    (None, contract.MAX_INFLATED), ("", contract.MAX_INFLATED), ("204800", 204800),
    ("100000", 100000), ("10000000", contract.MAX_INFLATED_HARD), ("abc", contract.MAX_INFLATED),
    ("0", contract.MAX_INFLATED), ("-5", contract.MAX_INFLATED),
])
def test_inflated_limit_setting(setting, limit):
    assert contract.inflated_limit(setting) == limit


def test_broken_gzip_and_json_are_400(keys, sinks):
    assert handle_batch(headers(), b"\x1f\x8b\x08\x00broken", keys, sinks).status == 400
    assert handle_batch(headers(), gzip.compress(b"{nope"), keys, sinks).status == 400
    assert handle_batch(headers(), gzip.compress(b'{"a": NaN}'), keys, sinks).status == 400
    assert handle_batch(headers(), gzip.compress(b"[" * 100000), keys, sinks).status == 400  # not 500


@pytest.mark.parametrize("mutate", [
    lambda b: b["labels"].append({"t": 1, "type": "x" * 4096, "value": None, "note": None}),
    lambda b: b["labels"].append({"t": 1, "type": "pothole", "value": None, "note": "a\u0000b"}),
    lambda b: b["labels"].append({"t": 1, "type": "pothole", "value": None, "note": "\ud800"}),
    lambda b: b.update(deviceId="D" * 129),
    lambda b: b["device"].update(thermal="x" * (contract.MAX_TEXT_LEN + 1)),
])
def test_strings_the_database_cant_store_are_400(mutate, batch, keys, sinks):
    mutate(batch)
    resp = handle_batch(headers(), gz(batch), keys, sinks)
    assert resp.status == 400, resp.body
    assert not sinks.events and not sinks.blobs


def test_a_long_note_is_still_accepted(batch, keys, sinks):
    batch["labels"].append({"t": 1, "type": "note", "value": None, "note": "é" * contract.MAX_TEXT_LEN})
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 200


def test_idempotency_key_mismatch_is_400(batch, keys, sinks):
    resp = handle_batch(headers(**{"x-idempotency-key": "x:1"}), gz(batch), keys, sinks)
    assert resp.status == 400
    assert not sinks.events


# --- Device keys are bound to a deviceId ------------------------------------------------------

def test_another_devices_key_is_403_and_nothing_is_stored(batch, keys, sinks):
    resp = handle_batch(headers(**{"x-device-key": OTHER_KEY}), gz(batch), keys, sinks)
    assert resp.status == 403  # the app retries 403: nothing is lost while the binding is fixed
    assert "OTHER-PHONE" in resp.body["error"]
    assert not sinks.events and not sinks.blobs


def test_probe_without_a_device_id_is_still_400_for_any_valid_key(keys, sinks):
    # Older app builds send {"probe": true} only: unchanged "reachable, key accepted".
    resp = handle_batch(headers(**{"x-device-key": OTHER_KEY, "x-probe": "1"}), gz({"probe": True}),
                        keys, sinks)
    assert resp.status == 400 and resp.body["error"].startswith("probe request")


def test_probe_naming_its_device_reports_a_key_stored_under_another_name(keys, sinks):
    probe = {"probe": True, "deviceId": "FIXTURE-DEVICE"}
    ok = handle_batch(headers(**{"x-probe": "1"}), gz(probe), keys, sinks)
    assert ok.status == 400 and ok.body["error"].startswith("probe request")
    wrong = handle_batch(headers(**{"x-device-key": OTHER_KEY, "x-probe": "1"}), gz(probe), keys, sinks)
    assert wrong.status == 403 and "OTHER-PHONE" in wrong.body["error"]
    assert not sinks.events and not sinks.blobs


def test_batch_from_a_renamed_key_goes_through_once_the_keys_reload(batch, sinks):
    from ingest_core.keys import hash_key

    class Clock:
        t = 0.0

        def __call__(self):
            return self.t

    stored = {hash_key(DEVICE_KEY): {"iphone-mihai"}}
    clock = Clock()
    keys = KeyStore(lambda: dict(stored), min_reload_s=60, clock=clock)
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 403
    stored[hash_key(DEVICE_KEY)] = {batch["deviceId"]}  # add-device-key.ps1 -RenameFrom iphone-mihai
    clock.t = 61  # the app retries 403 with backoff
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 200


def test_key_vault_failure_on_a_binding_reload_is_503(batch, sinks):
    from ingest_core.keys import hash_key

    class Clock:
        t = 0.0

        def __call__(self):
            return self.t

    state = {"fail": False}

    def loader():
        if state["fail"]:
            raise RuntimeError("vault down")
        return {hash_key(DEVICE_KEY): {"iphone-mihai"}}

    clock = Clock()
    keys = KeyStore(loader, min_reload_s=60, clock=clock)
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 403
    state["fail"] = True
    clock.t = 61
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 503


@pytest.mark.parametrize("key, device_id, status", [
    (REPLAY_KEY, "replay-FIXTURE-DEVICE", 200),   # replay key, any replay-… ID
    (REPLAY_KEY, "replay-SOMEONE", 200),
    (REPLAY_KEY, "FIXTURE-DEVICE", 403),          # but never as a phone
    (DEVICE_KEY, "replay-FIXTURE-DEVICE", 200),   # a phone replaying its own trip
    (DEVICE_KEY, "replay-OTHER-PHONE", 403),
    (DEVICE_KEY, "fixture-device", 200),          # case-insensitive
])
def test_replay_device_ids(key, device_id, status, batch, keys, sinks):
    batch["deviceId"] = device_id
    assert handle_batch(headers(**{"x-device-key": key}), gz(batch), keys, sinks).status == status


def test_downstream_failure_is_503_so_the_app_retries(batch, keys):
    assert handle_batch(headers(), gz(batch), keys, FakeSinks(fail=True)).status == 503


def test_key_vault_failure_is_503_not_401(batch, sinks):
    def broken():
        raise RuntimeError("vault down")
    assert handle_batch(headers(), gz(batch), KeyStore(broken), sinks).status == 503


# --- PUT /api/ingest/sessions/{id} --------------------------------------------------------

def test_start_and_stop_are_archived_separately(session_meta, keys, sinks):
    sid = session_meta["sessionId"]
    start = handle_session(sid, headers(**{"x-idempotency-key": f"{sid}:meta-start"}),
                           gz(session_meta), keys, sinks)
    assert start.status == 200 and start.body["phase"] == "start"

    session_meta.update(batchCount=5, endedAtUtc="2026-11-21T10:00:00.000Z")
    stop = handle_session(sid, headers(**{"x-idempotency-key": f"{sid}:meta-stop"}),
                          gz(session_meta), keys, sinks)
    assert stop.status == 200 and stop.body["phase"] == "stop"

    assert set(sinks.blobs) == {f"raw/session={sid}/session-start.json.gz",
                                f"raw/session={sid}/session-stop.json.gz"}
    assert [e[2]["phase"] for e in sinks.events] == ["start", "stop"]
    assert all(e[0] == session_meta["deviceId"] for e in sinks.events)  # same partition as batches


def test_session_without_device_id_is_400(session_meta, keys, sinks):
    """The key is bound to a deviceId, so metadata without one can't be attributed to a device."""
    sid = session_meta["sessionId"]
    session_meta["deviceId"] = ""
    assert handle_session(sid, headers(), gz(session_meta), keys, sinks).status == 400
    del session_meta["deviceId"]
    assert handle_session(sid, headers(), gz(session_meta), keys, sinks).status == 400
    assert not sinks.events


def test_session_of_another_device_is_403(session_meta, keys, sinks):
    sid = session_meta["sessionId"]
    resp = handle_session(sid, headers(**{"x-device-key": OTHER_KEY}), gz(session_meta), keys, sinks)
    assert resp.status == 403
    assert not sinks.events and not sinks.blobs


def test_session_retry_keeps_the_first_copy(session_meta, keys, sinks):
    sid = session_meta["sessionId"]
    first = gz(session_meta)
    assert handle_session(sid, headers(), first, keys, sinks).status == 200
    session_meta["vehicle"] = {"type": "bus"}
    resp = handle_session(sid, headers(), gz(session_meta), keys, sinks)
    assert resp.status == 200 and "archive=already-there" in resp.log_info
    assert sinks.blobs == {f"raw/session={sid}/session-start.json.gz": first}


def test_session_strings_are_capped(session_meta, keys, sinks):
    sid = session_meta["sessionId"]
    session_meta["vehicle"]["notes"] = "x" * (contract.MAX_TEXT_LEN + 1)
    assert handle_session(sid, headers(), gz(session_meta), keys, sinks).status == 400
    session_meta["vehicle"]["notes"] = "nul\u0000"
    assert handle_session(sid, headers(), gz(session_meta), keys, sinks).status == 400


def test_bad_session_path_is_404(session_meta, keys, sinks):
    assert handle_session("a/b", headers(), gz(session_meta), keys, sinks).status == 404
    assert handle_session("", headers(), gz(session_meta), keys, sinks).status == 404


def test_session_idempotency_key_must_name_phase(session_meta, keys, sinks):
    sid = session_meta["sessionId"]
    resp = handle_session(sid, headers(**{"x-idempotency-key": f"{sid}:meta-stop"}),
                          gz(session_meta), keys, sinks)
    assert resp.status == 400


def test_session_wrong_key_is_401(session_meta, keys, sinks):
    sid = session_meta["sessionId"]
    assert handle_session(sid, headers(**{"x-device-key": "bad"}), gz(session_meta), keys, sinks).status == 401


def test_huge_integer_is_400_not_500(batch, keys, sinks):
    """10**400 doesn't fit a float: math.isfinite would raise OverflowError (500, retried forever)."""
    for mutate in (lambda b: b["accelRaw"]["x"].__setitem__(0, 10**400),
                   lambda b: b.update(t0Up=10**400), lambda b: b.update(batchSeq=10**400),
                   lambda b: b["location"][0].update(tUtcMs=10**400)):
        b = json.loads(json.dumps(batch))
        mutate(b)
        resp = handle_batch(headers(), gzip.compress(json.dumps(b).encode()), keys, sinks)
        assert resp.status == 400, resp.body
    assert not sinks.events and not sinks.blobs


def test_huge_integer_in_session_metadata_is_400(session_meta, keys, sinks):
    session_meta["startUptimeSec"] = 10**400
    sid = session_meta["sessionId"]
    assert handle_session(sid, headers(), gz(session_meta), keys, sinks).status == 400
