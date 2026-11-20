import gzip
import json

from conftest import DEVICE_KEY, FakeSinks, gz, headers
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


def test_retry_overwrites_same_blob_and_answers_200(batch, keys, sinks):
    for _ in range(2):
        assert handle_batch(headers(), gz(batch), keys, sinks).status == 200
    assert len(sinks.blobs) == 1
    assert len(sinks.events) == 2  # duplicates are dropped in the database, not here


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


def test_wrong_content_encoding_and_type(batch, keys, sinks):
    assert handle_batch(headers(**{"Content-Encoding": "x-gzip"}), gz(batch), keys, sinks).status == 400
    assert handle_batch(headers(**{"Content-Type": "text/plain"}), gz(batch), keys, sinks).status == 400


def test_body_already_inflated_by_host_is_accepted(batch, keys, sinks):
    raw = json.dumps(batch).encode()
    assert handle_batch(headers(), raw, keys, sinks).status == 200
    (blob,) = sinks.blobs.values()
    assert json.loads(gzip.decompress(blob)) == batch


def test_too_large_is_413(batch, keys, sinks):
    batch["padding"] = "x" * (contract.MAX_INFLATED + 1)
    assert handle_batch(headers(), gz(batch), keys, sinks).status == 413


def test_broken_gzip_and_json_are_400(keys, sinks):
    assert handle_batch(headers(), b"\x1f\x8b\x08\x00broken", keys, sinks).status == 400
    assert handle_batch(headers(), gzip.compress(b"{nope"), keys, sinks).status == 400
    assert handle_batch(headers(), gzip.compress(b'{"a": NaN}'), keys, sinks).status == 400


def test_idempotency_key_mismatch_is_400(batch, keys, sinks):
    resp = handle_batch(headers(**{"x-idempotency-key": "x:1"}), gz(batch), keys, sinks)
    assert resp.status == 400
    assert not sinks.events


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


def test_session_without_device_id_uses_session_as_partition(session_meta, keys, sinks):
    session_meta["deviceId"] = ""
    sid = session_meta["sessionId"]
    assert handle_session(sid, headers(), gz(session_meta), keys, sinks).status == 200
    assert sinks.events[0][0] == sid


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
