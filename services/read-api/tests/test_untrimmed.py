"""No start/end privacy trim (D40): tracks, events, live positions and segment passes are served whole,
home included. Only fixes less accurate than MAX_HACC_M (or without an accuracy) are left out."""

import datetime as dt

import pytest

from conftest import UTC, make_batch, requires_db, session_meta

pytestmark = requires_db

SID = "22222222-3333-4444-8555-666666666666"
HOME = (46.77, 23.62)
STEP_DEG = 0.0005  # ≈ 55.6 m of latitude per fix


def _batches(fixture_batch, fixes, *, start=None, sid=SID, device="PHONE-1"):
    """One batch per fix; `fixes` are (lat, lon, hAcc) with hAcc -1 meaning "no accuracy"."""
    start = start or dt.datetime.now(UTC) - dt.timedelta(seconds=2 * len(fixes))
    out = []
    for i, (lat, lon, hacc) in enumerate(fixes):
        b = make_batch(fixture_batch, sid, i, start, lat, lon, device_id=device)
        b["location"][0]["hAcc"] = hacc
        out.append(b)
    return out


def _drive(n, start_index=1, hacc=5.0):
    return [(HOME[0] + i * STEP_DEG, HOME[1], hacc) for i in range(start_index, start_index + n)]


def _coords(client, sid=SID):
    r = client.get(f"/api/sessions/{sid}/track")
    assert r.status_code == 200, r.text
    return r.json()


def test_track_starts_at_home_and_skips_only_inaccurate_fixes(client, seed, fixture_batch):
    garage = [(HOME[0] + 0.004, HOME[1], -1), (HOME[0] + 0.004, HOME[1], 150.0), (HOME[0], HOME[1], 4.0)]
    drive = _drive(20)
    drive[10] = (drive[10][0], drive[10][1] + 0.001, 80.0)
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, garage + drive))

    track = _coords(client)
    coords = track["geometry"]["coordinates"]
    assert track["properties"]["trimmedM"] == 0
    assert len(coords) == 20  # home + 19 accurate drive fixes
    assert coords[0] == [pytest.approx(HOME[1]), pytest.approx(HOME[0])]


def test_short_trip_that_never_leaves_home_is_served(client, seed, fixture_batch):
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, [(HOME[0], HOME[1], 5.0)] * 5))
    assert len(_coords(client)["geometry"]["coordinates"]) == 5
    (dev,) = client.get("/api/live").json()["devices"]
    assert dev["lat"] == pytest.approx(HOME[0])


def test_ended_trip_keeps_its_end_and_events_there(client, seed, fixture_batch, dbname):
    import psycopg

    start = dt.datetime.now(UTC) - dt.timedelta(minutes=2)
    fixes = [(HOME[0], HOME[1], 5.0)] + _drive(19)
    seed(meta=[session_meta(SID), session_meta(SID, batchCount=20, endedAtUtc="2026-11-21T09:30:00.000Z")],
         batches=_batches(fixture_batch, fixes, start=start))
    assert len(_coords(client)["geometry"]["coordinates"]) == 20

    with psycopg.connect(dbname=dbname, autocommit=True) as conn:
        for i in (0, 19):  # at the start and at the very end
            conn.execute(
                "INSERT INTO events (session_id, type, t, geom, speed_ms, magnitude, confidence) VALUES "
                "(%s, 'pothole', %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 10, 5, 0.9)",
                (SID, start + dt.timedelta(seconds=2 * i + 0.5), HOME[1], HOME[0] + i * STEP_DEG))
    assert len(client.get(f"/api/sessions/{SID}/events").json()["features"]) == 2
    (s,) = client.get("/api/sessions").json()["sessions"]
    assert s["eventCounts"]["pothole"] == 2


def test_segment_pass_at_home_is_served_even_if_flagged_before_d40(client, seed, fixture_batch, dbname):
    import psycopg

    start = dt.datetime.now(UTC) - dt.timedelta(minutes=5)
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, [(HOME[0], HOME[1], 5.0)] + _drive(19),
                                                       start=start))
    with psycopg.connect(dbname=dbname, autocommit=True) as conn:
        conn.execute(
            "INSERT INTO segments (h3, center, boundary) VALUES ('8b1e00000000fff', "
            "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, "
            "ST_Buffer(ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 20))",
            (HOME[1], HOME[0], HOME[1], HOME[0]))
        conn.execute(
            "INSERT INTO segment_observations (session_id, pass_idx, h3, t_start, duration_s, aw_rms,"
            " n_windows, in_privacy_zone) VALUES (%s, 0, '8b1e00000000fff', %s, 1.5, 0.3, 7, true)",
            (SID, start + dt.timedelta(seconds=0.2)))
    (obs,) = client.get("/api/segments/8b1e00000000fff").json()["observations"]
    assert obs["sessionId"] == SID


def test_live_track_is_the_last_two_minutes(client, seed, fixture_batch):
    n = 150  # 5 minutes, one fix every 2 s
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, [(HOME[0], HOME[1], 5.0)] + _drive(n - 1)))
    (dev,) = client.get("/api/live").json()["devices"]
    assert 59 <= len(dev["track"]) <= 61
    assert dev["track"][-1][1] == pytest.approx(HOME[0] + (n - 1) * STEP_DEG)
