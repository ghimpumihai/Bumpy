"""The function must accept and reject exactly what the mock server (the app's test server) does,
apart from the stricter session ID rule."""

import gzip
import json

import pytest

from conftest import FIXTURE
from ingest_core import contract


def _outcome(fn, *args):
    try:
        return ("ok", fn(*args))
    except Exception as e:  # noqa: BLE001 - comparing behaviour, not types
        return ("invalid", str(e))


HEADING_OK = {"tUtcMs": 1763716532100, "magHeading": 91.0, "trueHeading": 95.0, "headingAcc": 10.0,
              "x": 1.0, "y": 2.0, "z": 3.0}
ACTIVITY_OK = {"t": 0.6, "stationary": False, "walking": False, "running": False, "automotive": True,
               "cycling": False, "unknown": False, "confidence": 2, "startUtcMs": 1763716500000}

BATCH_MUTATIONS = {
    "valid": lambda b: None,
    "probe": lambda b: b.clear() or b.update({"probe": True}),
    "probe naming its device": lambda b: b.clear() or b.update({"probe": True, "deviceId": "FIXTURE-DEVICE"}),
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
    "extra units key": lambda b: b["units"].update(magnetic="uT"),
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
    # Full-dataset blocks (02 D32), present in the app's fixture batch.
    "no optional blocks": lambda b: [b.pop(k) for k in ("magRaw", "absAltitude", "heading", "activity")],
    "magRaw not object": lambda b: b.update(magRaw=[]),
    "magRaw no t": lambda b: b["magRaw"].pop("t"),
    "magRaw column missing": lambda b: b["magRaw"].pop("y"),
    "magRaw length mismatch": lambda b: b["magRaw"]["x"].append(0.0),
    "magRaw non-numeric": lambda b: b.update(magRaw={"t": [0.0], "x": [None], "y": [0.0], "z": [0.0]}),
    "absAltitude column missing": lambda b: b["absAltitude"].pop("precisionM"),
    "absAltitude extra column wrong length": lambda b: b["absAltitude"].update(extra=[1.0] * 99),
    "heading not list": lambda b: b.update(heading={}),
    "heading valid": lambda b: b["heading"].append(dict(HEADING_OK)),
    "heading tUtcMs float": lambda b: b["heading"].append(dict(HEADING_OK, tUtcMs=1.5)),
    "heading missing number": lambda b: b["heading"].append({"tUtcMs": 1, "magHeading": 1.0}),
    "activity not list": lambda b: b.update(activity=None),
    "activity valid": lambda b: b["activity"].append(dict(ACTIVITY_OK)),
    "activity string bool": lambda b: b["activity"].append(dict(ACTIVITY_OK, automotive="yes")),
    "activity confidence 5": lambda b: b["activity"].append(dict(ACTIVITY_OK, confidence=5)),
    "activity confidence float": lambda b: b["activity"].append(dict(ACTIVITY_OK, confidence=1.0)),
    "activity confidence bool": lambda b: b["activity"].append(dict(ACTIVITY_OK, confidence=True)),
    "activity startUtcMs missing": lambda b: b["activity"].append(
        {k: v for k, v in ACTIVITY_OK.items() if k != "startUtcMs"}),
    # String limits: what PostgreSQL can't index or store.
    "deviceId 128": lambda b: b.update(deviceId="D" * 128),
    "deviceId 129": lambda b: b.update(deviceId="D" * 129),
    "label type 64": lambda b: b["labels"].append({"t": 1, "type": "x" * 64, "value": None, "note": None}),
    "label type 4 KB": lambda b: b["labels"].append({"t": 1, "type": "x" * 4096, "value": None, "note": None}),
    "note 2000": lambda b: b["labels"].append({"t": 1, "type": "note", "value": None, "note": "n" * 2000}),
    "note 2001": lambda b: b["labels"].append({"t": 1, "type": "note", "value": None, "note": "n" * 2001}),
    "note NUL": lambda b: b["labels"].append({"t": 1, "type": "note", "value": None, "note": "a\x00b"}),
    "label value surrogate": lambda b: b["labels"].append({"t": 1, "type": "x", "value": "\udc00", "note": None}),
    "deviceId NUL": lambda b: b.update(deviceId="a\x00"),
    "extra key too long": lambda b: b.update({"k" * 2001: 1}),
    "nested extra NUL": lambda b: b["device"].update(netType=["ok", {"deep": "\x00"}]),
    "thermal too long": lambda b: b["device"].update(thermal="t" * 2001),
    "empty batch": lambda b: [blk.update({k: [] for k in blk}) for blk in
                              (b["deviceMotion"], b["accelRaw"], b["gyroRaw"], b["altimeter"])]
                             and b.update(location=[], labels=[]),
}


@pytest.mark.parametrize("name", [k for k in BATCH_MUTATIONS if k != "not object"])
def test_batch_matches_mock(name, batch, mock_server):
    BATCH_MUTATIONS[name](batch)
    mine = _outcome(contract.validate_batch, batch)
    theirs = _outcome(mock_server.validate, batch)
    assert mine == theirs
    valid = name in ("valid", "empty batch", "no optional blocks", "heading valid", "activity valid",
                     "deviceId 128", "label type 64", "note 2000", "extra units key")
    assert mine[0] == ("ok" if valid else "invalid"), mine


def test_fixture_batch_is_valid(batch, mock_server):
    contract.validate_batch(batch)
    mock_server.validate(batch)
    assert {"magRaw", "absAltitude", "heading", "activity"} <= set(batch)  # the mutations above use them


def test_non_object_rejected_like_mock(mock_server):
    assert _outcome(contract.validate_batch, [1])[1] == _outcome(mock_server.validate, [1])[1]


OLD_AUDIO_LEVELS = {  # what builds before D48 send, well-formed or not: never read
    "valid": {"t": [0.0], "avgDbfs": [-40.0], "peakDbfs": [-20.0]},
    "malformed": {"t": [0.0, 0.1], "avgDbfs": ["loud"]},
    "null": None,
}


@pytest.mark.parametrize("level", ["absent", *OLD_AUDIO_LEVELS])
def test_audio_level_ignored_by_both(level, batch, mock_server):
    """D48 (no audio): neither side requires or checks audioLevel; builds before D48 still send it."""
    batch.pop("audioLevel", None)  # whether or not the fixture still has it
    if level != "absent":
        batch["audioLevel"] = OLD_AUDIO_LEVELS[level]
    assert _outcome(contract.validate_batch, batch) == _outcome(mock_server.validate, batch) == ("ok", None)


@pytest.mark.parametrize("enabled", [None, True, False, "yes", 1])
def test_audio_enabled_ignored_by_both(enabled, session_meta, mock_server):
    """D48: session.json audioEnabled (builds before D48) is neither required nor checked."""
    sid = session_meta["sessionId"]
    session_meta.pop("audioEnabled", None)
    if enabled is not None:
        session_meta["audioEnabled"] = enabled
    assert (_outcome(contract.validate_session_meta, session_meta, sid)
            == _outcome(mock_server.validate_session_meta, session_meta, sid) == ("ok", "start"))


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
    "batchCount negative": lambda m: m.update(batchCount=-1, recovered=True),
    "startUptime string": lambda m: m.update(startUptimeSec="1"),
    "deviceId missing": lambda m: m.pop("deviceId"),
    "deviceId empty": lambda m: m.update(deviceId=""),
    "deviceId null": lambda m: m.update(deviceId=None),
    "deviceId 129": lambda m: m.update(deviceId="D" * 129),
    "vehicle notes 2001": lambda m: m["vehicle"].update(notes="v" * 2001),
    "mount NUL": lambda m: m["mount"].update(location="\x00"),
    "stop with long note": lambda m: m.update(batchCount=1, recovered=True, conditions={"notes": "c" * 2001}),
}


@pytest.mark.parametrize("name", list(SESSION_MUTATIONS))
def test_session_matches_mock(name, session_meta, mock_server):
    path_id = session_meta["sessionId"]
    SESSION_MUTATIONS[name](session_meta)
    mine = _outcome(contract.validate_session_meta, session_meta, path_id)
    theirs = _outcome(mock_server.validate_session_meta, session_meta, path_id)
    assert mine == theirs


def _app_session_copies():
    """The app's Stop copy (fixture written by the Swift tests) and the Start copy it sends first:
    no batchCount, endedAtUtc and stats null (spec §6.1)."""
    stop = json.loads(gzip.decompress((FIXTURE.parent / "session_meta_stop_v1.json.gz").read_bytes()))
    start = {k: v for k, v in stop.items() if k != "batchCount"}
    start.update(endedAtUtc=None, stats=None)
    return {"start": start, "stop": stop}


@pytest.mark.parametrize("phase", ["start", "stop"])
def test_app_session_copies_accepted_by_both(phase, mock_server):
    m = _app_session_copies()[phase]
    assert contract.validate_session_meta(m, m["sessionId"]) == phase
    assert mock_server.validate_session_meta(m, m["sessionId"]) == phase


@pytest.mark.parametrize("raw", [
    b"\x1f\x8b\x08\x00garbage",
    b"",
])
def test_gzip_errors_match_mock(raw, mock_server):
    mine = _outcome(contract.gunzip_one_member, raw, 1000)
    theirs = _outcome(mock_server.gunzip_one_member, raw, 1000)
    assert mine == theirs


def _decoded(mod, raw, limit):
    """decode + parse as both servers do; the 400 reason for a non-gzip body names both formats."""
    body, was_gzip = mod.decode_body(raw, limit)
    try:
        return mod.parse_json(body)
    except ValueError as e:
        raise ValueError(str(e) if was_gzip else mod.not_gzip_reason(str(e)))


_DOC = {"a": [1, 2.5, "x"]}
DECODE_CASES = {
    "gzip": gzip.compress(json.dumps(_DOC).encode()),
    "already inflated, header removed": json.dumps(_DOC).encode(),
    "already inflated, too large": json.dumps({"p": "x" * 1000}).encode(),
    "gzip, too large inflated": gzip.compress(json.dumps({"p": "x" * 1000}).encode()),
    "neither gzip nor JSON": b"\x8b\x0b\x80brotli?",
    "gzip of non-JSON": gzip.compress(b"{nope"),
    "plain NaN": b'{"a": NaN}',
    "two gzip members": gzip.compress(b"{}") + gzip.compress(b"{}"),
    "trailing data": gzip.compress(b"{}") + b"junk",
    "truncated": gzip.compress(json.dumps(_DOC).encode())[:-4],
    "nested too deeply": b"[" * 5000 + b"]" * 5000,
    "empty": b"",
}


@pytest.mark.parametrize("name", list(DECODE_CASES))
def test_decoding_matches_mock(name, mock_server):
    raw = DECODE_CASES[name]
    mine = _outcome(_decoded, contract, raw, 1000 if "too large" in name else 100_000)
    theirs = _outcome(_decoded, mock_server, raw, 1000 if "too large" in name else 100_000)
    assert mine == theirs
    if name.startswith(("gzip", "already inflated, header")) and "too large" not in name and "non-JSON" not in name:
        assert mine == ("ok", _DOC)
