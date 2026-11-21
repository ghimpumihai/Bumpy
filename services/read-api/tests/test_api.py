"""The read API against a real PostGIS, with data written by the processor's own Store.

Key sets are copied from the dashboard's TypeScript types (dashboard/src/types/), which are the
contract: a missing or misspelled field would break a dashboard page without any server error.
"""

import datetime as dt
import re

import pytest

from conftest import UTC, make_batch, requires_db, session_meta

pytestmark = requires_db

ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")

SUMMARY_KEYS = {
    "sessionId", "source", "isMock", "replayOf", "deviceId", "vehicle", "mount", "people", "audioEnabled",
    "startedAt", "endedAt", "durationS", "distanceM", "status", "incomplete", "qualityStatus",
    "validFraction", "includeInAgg", "exclusionReasons", "roughnessEligible", "sicknessExperimental",
    "msdvZ", "msiPct", "eventCounts", "ratingsCount",
}
DETAIL_KEYS = SUMMARY_KEYS | {"quality", "detection", "sickness", "processedAt", "processorVersion"}
QUALITY_KEYS = {"streams", "gps", "validFraction", "invalidSeconds", "rejectedBatches", "lateBatches",
                "duplicateBatches"}
LIVE_DEVICE_KEYS = {
    "deviceId", "sessionId", "source", "sessionStatus", "vehicleType", "updatedAt", "receivedAt", "lat",
    "lon", "speedMs", "courseDeg", "hAccM", "roughnessNow", "msdvSoFar", "latestRating", "battery",
    "thermal", "track",
}
OVERVIEW_KEYS = {"sessions", "distanceKm", "segments", "confirmedPotholes", "speedBumps", "lastProcessedAt",
                 "aggregation"}
AGGREGATION_KEYS = {"method", "beta", "refSpeedKmh", "vehicleEffects", "fittedAt"}

SID = "11111111-2222-4333-8444-555555555555"
STEP_DEG = 0.0005  # ≈ 55 m of latitude per batch


def _trip(fixture_batch, n, *, start=None, labels_at=None, sid=SID, device="PHONE-1"):
    start = start or dt.datetime.now(UTC) - dt.timedelta(seconds=2 * n)
    out = []
    for i in range(n):
        labels = labels_at.get(i, ()) if labels_at else ()
        out.append(make_batch(fixture_batch, sid, i, start, 46.77 + i * STEP_DEG, 23.62,
                              device_id=device, labels=labels))
    return out


def _ok(client, path, **params):
    r = client.get(path, params=params)
    assert r.status_code == 200, (path, r.status_code, r.text)
    assert r.headers["content-type"].startswith("application/json")
    return r.json()


def _err(client, path, status, **params):
    r = client.get(path, params=params)
    assert r.status_code == status, (path, r.status_code, r.text)
    assert set(r.json()) == {"error"}
    return r.json()["error"]


# --- Empty database: every route answers with a valid envelope ---------------------------

def test_empty_database_shapes(client):
    ov = _ok(client, "/api/overview")
    assert set(ov) == OVERVIEW_KEYS and set(ov["aggregation"]) == AGGREGATION_KEYS
    assert ov["aggregation"]["method"] == "none" and ov["sessions"]["total"] == 0
    assert _ok(client, "/api/sessions") == {"sessions": []}
    assert _ok(client, "/api/quality") == {"sessions": []}
    live = _ok(client, "/api/live")
    assert live["devices"] == [] and ISO.match(live["serverTime"])
    empty_fc = {"type": "FeatureCollection", "features": []}
    assert _ok(client, "/api/segments", vehicle="all") == empty_fc
    assert _ok(client, "/api/events", vehicle="bus", type="pothole") == empty_fc


@pytest.mark.parametrize("suffix", ["", "/series", "/track", "/events", "/labels"])
def test_unknown_session_is_404(client, suffix):
    _err(client, f"/api/sessions/nope{suffix}", 404)


@pytest.mark.parametrize("path,params", [
    ("/api/sessions", {"source": "satellite"}),
    ("/api/sessions", {"vehicle": "rocket"}),
    ("/api/segments", {"vehicle": "bike"}),  # the map filter only has all/car/bus/tram
    ("/api/events", {"type": "crater"}),
])
def test_bad_parameters_are_400(client, path, params):
    _err(client, path, 400, **params)


def test_segment_detail(client):
    assert "not an H3 cell" in _err(client, "/api/segments/hello", 400)
    _err(client, "/api/segments/8a1fb46622dffff", 404)


def test_unknown_route_is_404_with_error_body(client):
    _err(client, "/api/nothing-here", 404)


# --- A live trip --------------------------------------------------------------------------

def test_live_trip_end_to_end(client, seed, fixture_batch):
    rating = [{"t": 0.5, "type": "sickness", "value": "3", "note": None}]
    seed(meta=[session_meta(SID)], batches=_trip(fixture_batch, 20, labels_at={15: rating}))

    (s,) = _ok(client, "/api/sessions")["sessions"]
    assert set(s) == SUMMARY_KEYS
    assert (s["sessionId"], s["source"], s["status"], s["vehicle"]["type"]) == (SID, "live", "live", "bus")
    assert s["exclusionReasons"] == ["live_only"] and s["includeInAgg"] is False
    assert s["roughnessEligible"] is True and s["sicknessExperimental"] is False
    assert s["ratingsCount"] == 1 and s["eventCounts"] == {"pothole": 0, "speed_bump": 0, "rail_joint": 0}
    assert 1000 < s["distanceM"] < 1100  # 19 steps of ≈ 55.6 m
    assert ISO.match(s["startedAt"]) and s["endedAt"] is None

    d = _ok(client, f"/api/sessions/{SID}")
    assert set(d) == DETAIL_KEYS and set(d["quality"]) == QUALITY_KEYS
    assert d["quality"]["gps"]["fixes"] == 20
    assert [r["value"] for r in d["sickness"]["ratings"]] == [3]

    track = _ok(client, f"/api/sessions/{SID}/track")
    coords, times = track["geometry"]["coordinates"], track["properties"]["times"]
    assert len(coords) == len(times) == len(track["properties"]["speeds"])
    assert all(isinstance(t, int) for t in times)
    # Live trip: only the first 200 m are hidden (≈ 4 fixes), the end is still public.
    assert 15 <= len(coords) <= 16 and coords[-1][1] == pytest.approx(46.77 + 19 * STEP_DEG)

    (dev,) = _ok(client, "/api/live")["devices"]
    assert set(dev) == LIVE_DEVICE_KEYS
    assert (dev["deviceId"], dev["sessionId"], dev["sessionStatus"], dev["vehicleType"]) == \
        ("PHONE-1", SID, "live", "bus")
    assert ISO.match(dev["updatedAt"]) and ISO.match(dev["receivedAt"])
    assert dev["lat"] == pytest.approx(46.77 + 19 * STEP_DEG) and dev["speedMs"] == 10.0
    assert dev["latestRating"]["value"] == 3 and len(dev["track"]) >= 2

    labels = _ok(client, f"/api/sessions/{SID}/labels")["labels"]
    assert [lab["type"] for lab in labels] == ["sickness"] and ISO.match(labels[0]["tUtc"])
    series = _ok(client, f"/api/sessions/{SID}/series")
    assert set(series) == {"t", "aVert", "aLat", "aLon", "speed", "msdv"}
    assert len({len(v) for v in series.values()}) == 1  # columnar: equal lengths

    ov = _ok(client, "/api/overview")
    assert ov["sessions"]["total"] == 1 and ov["sessions"]["live"] == 1


def test_device_hidden_during_first_200_m(client, seed, fixture_batch):
    seed(batches=_trip(fixture_batch, 3))  # ≈ 110 m
    assert _ok(client, "/api/live")["devices"] == []


def test_silent_device_drops_off_live_view(client, seed, fixture_batch):
    old = dt.datetime.now(UTC) - dt.timedelta(minutes=5)
    seed(batches=_trip(fixture_batch, 20, start=old), received_at=old)
    assert _ok(client, "/api/live")["devices"] == []


def test_ended_trip_trims_both_ends_and_leaves_live_view(client, seed, fixture_batch):
    stop = session_meta(SID, batchCount=20, endedAtUtc="2026-11-21T09:30:00.000Z")
    seed(meta=[session_meta(SID)], batches=_trip(fixture_batch, 20))
    seed(meta=[stop])

    s = _ok(client, f"/api/sessions/{SID}")
    assert s["status"] == "processing" and s["endedAt"] == "2026-11-21T09:30:00.000Z"
    coords = _ok(client, f"/api/sessions/{SID}/track")["geometry"]["coordinates"]
    assert 11 <= len(coords) <= 13  # ≈ 4 fixes hidden at each end
    assert _ok(client, "/api/live")["devices"] == []


def test_filters(client, seed, fixture_batch):
    seed(meta=[session_meta(SID, vehicle="tram")], batches=_trip(fixture_batch, 2))
    assert len(_ok(client, "/api/sessions", vehicle="tram")["sessions"]) == 1
    assert _ok(client, "/api/sessions", vehicle="bus")["sessions"] == []
    assert _ok(client, "/api/sessions", source="replay")["sessions"] == []


def test_unknown_context_defaults_keep_the_shape(client, seed, fixture_batch):
    seed(batches=_trip(fixture_batch, 2))  # no session.json yet
    (s,) = _ok(client, "/api/sessions")["sessions"]
    assert s["vehicle"] == {"type": "unknown", "makeModel": "", "line": None}
    assert s["mount"] == {"location": "", "phoneOrientation": "", "rigid": False, "handheld": False}
    assert set(s["people"]) == {"operatorSeat", "raterSeat", "raterPosture", "passengerCount"}
    assert "unknown_context" in s["exclusionReasons"] and s["roughnessEligible"] is False


def _with_motion(b: dict, vert) -> dict:
    """Replace the batch's deviceMotion with 2 s of 100 Hz samples (phone screen up)."""
    import numpy as np

    rel = np.arange(200) / 100.0
    t0 = b["t0UtcMs"] / 1000
    zeros = [0.0] * 200
    b["deviceMotion"] = {"t": rel.tolist(), "ua_x": zeros, "ua_y": zeros,
                         "ua_z": (vert(t0 + rel) / 9.80665).tolist(),
                         "g_x": zeros, "g_y": zeros, "g_z": [-1.0] * 200,
                         "rr_x": zeros, "rr_y": zeros, "rr_z": zeros,
                         "q_w": [1.0] * 200, "q_x": zeros, "q_y": zeros, "q_z": zeros}
    return b


def test_signal_results_are_served(client, seed, fixture_batch):
    import numpy as np

    start = dt.datetime.now(UTC) - dt.timedelta(seconds=60)
    pothole_at = start.timestamp() + 2 * 15 + 1.0  # batch 15, ≈ 830 m in: outside the privacy zones

    def vert(t):
        return 0.8 * np.sin(2 * np.pi * 0.2 * t) + 15.0 * np.exp(-((t - pothole_at) / 0.01) ** 2)

    batches = [_with_motion(b, vert) for b in _trip(fixture_batch, 30, start=start)]
    seed(meta=[session_meta(SID)], batches=batches)

    series = _ok(client, f"/api/sessions/{SID}/series")
    assert 290 <= len(series["t"]) <= 300 and all(isinstance(t, int) for t in series["t"])
    assert series["msdv"] == sorted(series["msdv"])  # a dose only grows
    assert max(abs(v) for v in series["aVert"]) > 5  # the pothole spike

    s = _ok(client, f"/api/sessions/{SID}")
    assert s["msdvZ"] > 0 and s["msiPct"] == pytest.approx(s["msdvZ"] / 3, abs=1e-4)
    assert s["sickness"]["msdvZ"] == s["msdvZ"]
    assert s["eventCounts"] == {"pothole": 1, "speed_bump": 0, "rail_joint": 0}

    (ev,) = _ok(client, f"/api/sessions/{SID}/events")["features"]
    props = ev["properties"]
    assert ev["geometry"]["type"] == "Point" and props["type"] == "pothole"
    assert set(props) == {"id", "sessionId", "type", "tUtc", "speedKmh", "magnitude", "confidence",
                          "matchedLabel", "vehicleType"}
    assert props["speedKmh"] == 36.0 and props["vehicleType"] == "bus" and ISO.match(props["tUtc"])

    (dev,) = _ok(client, "/api/live")["devices"]
    assert dev["msdvSoFar"] == pytest.approx(s["msdvZ"], rel=1e-3) and dev["roughnessNow"] is not None

    # Not finalized, so not part of the shared map yet.
    assert _ok(client, "/api/events", vehicle="all")["features"] == []


SEGMENT_KEYS = {
    "h3", "vehicleType", "nSessions", "nPasses", "meanSpeedKmh", "roughness", "roughnessPctl",
    "roughnessMethod", "potholeHits", "potholePasses", "potholeRatio", "potholeConfirmed", "sicknessAwRms",
    "msi1hPct", "sicknessSessions",
}
SEGMENT_DETAIL_KEYS = {"h3", "center", "byVehicle", "sicknessBySeat", "observations", "updatedAt"}
OBSERVATION_KEYS = {"sessionId", "vehicleType", "tStart", "speedKmh", "roughnessRms", "awRms", "potholeCount",
                    "includedInAgg"}
SICKNESS_SPLIT_KEYS = {"vehicleType", "raterSeat", "raterPosture", "sicknessAwRms", "msi1hPct", "nSessions"}


def test_finalized_trip_reaches_the_map(client, seed, dbname, fixture_batch, tmp_path):
    """Stream a trip, finalize it from its raw archive (the finalize job's own code), then read the
    aggregated map, a segment, the overview and the session's quality panel."""
    import gzip
    import json

    import numpy as np
    import psycopg

    from roadride import finalize

    start = dt.datetime.now(UTC) - dt.timedelta(seconds=60)
    pothole_at = start.timestamp() + 2 * 15 + 1.0

    def vert(t):
        return 0.8 * np.sin(2 * np.pi * 0.2 * t) + 15.0 * np.exp(-((t - pothole_at) / 0.01) ** 2)

    batches = [_with_motion(b, vert) for b in _trip(fixture_batch, 30, start=start)]
    metas = [session_meta(SID), session_meta(SID, batchCount=30, endedAtUtc=dt.datetime.now(UTC).isoformat())]
    seed(meta=metas[:1], batches=batches)
    seed(meta=metas[1:])
    folder = tmp_path / "raw" / f"session={SID}"
    folder.mkdir(parents=True)
    for b in batches:
        (folder / f"{b['batchSeq']:08d}.json.gz").write_bytes(gzip.compress(json.dumps(b).encode()))
    for m, phase in zip(metas, ("start", "stop")):
        (folder / f"session-{phase}.json.gz").write_bytes(gzip.compress(json.dumps(m).encode()))
    with psycopg.connect(dbname=dbname) as conn:
        assert finalize.handle(conn, finalize.DirArchive(tmp_path), json.dumps({"sessionId": SID}).encode()) \
            == ("complete", SID)

    s = _ok(client, f"/api/sessions/{SID}")
    assert (s["status"], s["includeInAgg"], s["exclusionReasons"]) == ("complete", True, [])
    assert 0 < s["validFraction"] <= 1 and ISO.match(s["processedAt"])
    assert s["quality"]["streams"]["deviceMotion"]["expectedHz"] == 100.0

    fc = _ok(client, "/api/segments", vehicle="all")
    assert fc["type"] == "FeatureCollection" and len(fc["features"]) > 5
    feature = fc["features"][0]
    assert feature["geometry"]["type"] == "Polygon" and len(feature["geometry"]["coordinates"][0]) == 7
    assert set(feature["properties"]) == SEGMENT_KEYS
    assert feature["properties"]["roughnessMethod"] == "percentile"  # one trip can't fit the model
    assert _ok(client, "/api/segments", vehicle="bus")["features"]
    assert _ok(client, "/api/segments", vehicle="tram")["features"] == []

    detail = _ok(client, f"/api/segments/{feature['properties']['h3']}")
    assert set(detail) == SEGMENT_DETAIL_KEYS and ISO.match(detail["updatedAt"])
    assert [a["vehicleType"] for a in detail["byVehicle"]] == ["all", "bus"]
    (obs,) = detail["observations"]
    assert set(obs) == OBSERVATION_KEYS and obs["includedInAgg"] is True and obs["vehicleType"] == "bus"
    assert all(set(x) == SICKNESS_SPLIT_KEYS for x in detail["sicknessBySeat"])

    ov = _ok(client, "/api/overview")
    assert ov["segments"] == len(fc["features"]) and ov["distanceKm"] > 1
    assert ov["sessions"]["includedInAgg"] == 1 and ISO.match(ov["lastProcessedAt"])
    assert ov["aggregation"]["method"] == "percentile" and ISO.match(ov["aggregation"]["fittedAt"])

    # Finalized, so its pothole is on the shared map now.
    assert len(_ok(client, "/api/events", vehicle="all")["features"]) == 1


def test_cors_only_for_configured_origin(dbname, monkeypatch):
    from fastapi.testclient import TestClient

    from app.db import make_pool
    from app.main import create_app

    monkeypatch.setenv("CORS_ALLOWED_ORIGINS", "https://dash.example")
    with TestClient(create_app(make_pool(dbname))) as c:
        ok = c.get("/api/overview", headers={"Origin": "https://dash.example"})
        assert ok.headers.get("access-control-allow-origin") == "https://dash.example"
        other = c.get("/api/overview", headers={"Origin": "https://evil.example"})
        assert "access-control-allow-origin" not in other.headers
