"""The function must accept and reject exactly what the mock server (the app's test server) does,
apart from the stricter session ID rule."""

import pytest

from ingest_core import contract


def _outcome(fn, *args):
    try:
        return ("ok", fn(*args))
    except Exception as e:  # noqa: BLE001 - comparing behaviour, not types
        return ("invalid", str(e))


BATCH_MUTATIONS = {
    "valid": lambda b: None,
    "probe": lambda b: b.clear() or b.update({"probe": True}),
    "not object": None,  # handled below
    "missing key": lambda b: b.pop("labels"),
    "schemaVersion 2": lambda b: b.update(schemaVersion=2),
    "schemaVersion float": lambda b: b.update(schemaVersion=1.0),
    "schemaVersion bool": lambda b: b.update(schemaVersion=True),
    "negative batchSeq": lambda b: b.update(batchSeq=-1),
    "bad t0Utc format": lambda b: b.update(t0Utc="2026-11-21T09:15:32Z"),
    "impossible date": lambda b: b.update(t0Utc="2026-13-40T09:15:32.120Z"),
    "t0Up string": lambda b: b.update(t0Up="1"),
    "wrong units": lambda b: b["units"].update(accel="m/s2"),
    "empty source": lambda b: b.update(source=""),
    "t0UtcMs float": lambda b: b.update(t0UtcMs=1.5),
    "fieldUnits bad": lambda b: b.update(fieldUnits={"a": 1}),
    "column length mismatch": lambda b: b["accelRaw"]["x"].append(0.0),
    "column missing": lambda b: b["gyroRaw"].pop("z"),
    "column non-numeric": lambda b: b["accelRaw"].update(x=["a"] * len(b["accelRaw"]["t"])),
    "location not list": lambda b: b.update(location={}),
    "location tUtcMs float": lambda b: b.update(location=[{"tUtcMs": 1.0, "lat": 0, "lon": 0, "alt": 0,
                                                             "hAcc": 0, "speed": 0, "speedAcc": 0, "course": 0}]),
    "location out of range": lambda b: b.update(location=[{"tUtcMs": 1, "lat": 91, "lon": 0, "alt": 0,
                                                             "hAcc": 0, "speed": 0, "speedAcc": 0, "course": 0}]),
    "label missing null": lambda b: b.update(labels=[{"t": 1, "type": "pothole", "value": None}]),
    "label value number": lambda b: b.update(labels=[{"t": 1, "type": "x", "value": 3, "note": None}]),
    "device lowPower string": lambda b: b["device"].update(lowPower="no"),
    "empty batch": lambda b: [blk.update({k: [] for k in blk}) for blk in
                              (b["deviceMotion"], b["accelRaw"], b["gyroRaw"], b["altimeter"], b["audioLevel"])]
                             and b.update(location=[], labels=[]),
}


@pytest.mark.parametrize("name", [k for k in BATCH_MUTATIONS if k != "not object"])
def test_batch_matches_mock(name, batch, mock_server):
    BATCH_MUTATIONS[name](batch)
    mine = _outcome(contract.validate_batch, batch)
    theirs = _outcome(mock_server.validate, batch)
    assert mine[0] == theirs[0], (mine, theirs)
    if mine[0] == "invalid":
        assert mine[1] == theirs[1]


def test_fixture_batch_is_valid(batch):
    contract.validate_batch(batch)


def test_non_object_rejected_like_mock(mock_server):
    assert _outcome(contract.validate_batch, [1])[1] == _outcome(mock_server.validate, [1])[1]


@pytest.mark.parametrize("sid", ["a/b", "../x", "x" * 129, "has space"])
def test_session_id_is_stricter_than_mock(sid, batch, mock_server):
    batch["sessionId"] = sid
    assert _outcome(mock_server.validate, batch)[0] == "ok"
    assert _outcome(contract.validate_batch, batch)[0] == "invalid"


SESSION_MUTATIONS = {
    "start": lambda m: None,
    "stop": lambda m: m.update(batchCount=10, endedAtUtc="2026-11-21T10:00:00.000Z"),
    "stop recovered": lambda m: m.update(batchCount=10, recovered=True),
    "stop without end": lambda m: m.update(batchCount=10),
    "id mismatch": lambda m: m.update(sessionId="other"),
    "no endedAtUtc key": lambda m: m.pop("endedAtUtc"),
    "recovered string": lambda m: m.update(recovered="no"),
    "vehicle missing": lambda m: m.pop("vehicle"),
    "audioEnabled string": lambda m: m.update(audioEnabled="yes"),
    "batchCount negative": lambda m: m.update(batchCount=-1, recovered=True),
    "startUptime string": lambda m: m.update(startUptimeSec="1"),
}


@pytest.mark.parametrize("name", list(SESSION_MUTATIONS))
def test_session_matches_mock(name, session_meta, mock_server):
    path_id = session_meta["sessionId"]
    SESSION_MUTATIONS[name](session_meta)
    mine = _outcome(contract.validate_session_meta, session_meta, path_id)
    theirs = _outcome(mock_server.validate_session_meta, session_meta, path_id)
    assert mine == theirs


@pytest.mark.parametrize("raw", [
    b"\x1f\x8b\x08\x00garbage",
    b"",
])
def test_gzip_errors_match_mock(raw, mock_server):
    mine = _outcome(contract.gunzip_one_member, raw, 1000)
    theirs = _outcome(mock_server.gunzip_one_member, raw, 1000)
    assert mine == theirs
