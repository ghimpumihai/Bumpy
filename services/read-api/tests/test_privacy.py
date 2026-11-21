"""Privacy trimming (plan §11, API.md): no public position within 200 m of where a trip starts or ends.

The rule is a radius around the first (and, once ended, last) accurate fix, not a path length, so GPS
jitter while parked or a bad first fix in a garage can't open the track while the phone is at home.
"""

import datetime as dt
import math

import pytest

from conftest import UTC, make_batch, requires_db, session_meta

pytestmark = requires_db

SID = "22222222-3333-4444-8555-666666666666"
HOME = (46.77, 23.62)
STEP_DEG = 0.0005  # ≈ 55.6 m of latitude per fix while driving


def _metres(lat1, lon1, lat2, lon2):
    """Haversine distance, good to well under 1 % at these scales."""
    r = 6_371_008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


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


def _jitter(n, metres=30.0, hacc=8.0):
    """Parked at home: every fix jumps up to `metres` around it, so the path length grows fast."""
    out = []
    for i in range(n):
        dlat = (metres / 111_320) * (1 if i % 2 else -1)
        dlon = (metres / (111_320 * math.cos(math.radians(HOME[0])))) * (1 if i % 3 else -1)
        out.append((HOME[0] + dlat, HOME[1] + dlon, hacc))
    return out


def _track(client, sid=SID):
    r = client.get(f"/api/sessions/{sid}/track")
    assert r.status_code == 200, r.text
    return r.json()


def _assert_far_from(coords, origin, limit=200.0):
    for lon, lat in coords:
        assert _metres(lat, lon, *origin) > limit, (lat, lon)


def _insert_event(dbname, sid, t, lat, lon):
    import psycopg

    with psycopg.connect(dbname=dbname, autocommit=True) as conn:
        conn.execute(
            "INSERT INTO events (session_id, type, t, geom, speed_ms, magnitude, confidence) VALUES "
            "(%s, 'pothole', %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 10, 5, 0.9)",
            (sid, t, lon, lat))


def test_parked_jitter_does_not_leak_home(client, seed, fixture_batch):
    # 2 min parked with ±30 m jitter (≈ 2 km of "path"), one accurate-looking 300 m outlier, then drive.
    parked = [(HOME[0], HOME[1], 6.0)] + _jitter(60)
    parked[30] = (HOME[0] + 300 / 111_320, HOME[1], 10.0)
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, parked + _drive(20)))

    coords = _track(client)["geometry"]["coordinates"]
    _assert_far_from(coords, HOME)
    # Public from the first drive fix outside 200 m (fix 4, ≈ 222 m) to the end: the trip is live.
    assert len(coords) == 17
    assert coords[0][1] == pytest.approx(HOME[0] + 4 * STEP_DEG)

    (dev,) = client.get("/api/live").json()["devices"]
    _assert_far_from(dev["track"], HOME)


def test_garage_start_with_bad_accuracy(client, seed, fixture_batch):
    # In the garage: no accuracy, then poor fixes (one of them 400 m up the road), then a good fix at
    # home. A poor fix must not become the anchor, or home would look 400 m away from the start.
    garage = [(HOME[0] + 400 / 111_320, HOME[1], -1),
              (HOME[0] + 400 / 111_320, HOME[1], 150.0),
              (HOME[0] + 0.0002, HOME[1] - 0.0003, 90.0),
              (HOME[0], HOME[1], 4.0)]
    drive = _drive(20)
    drive[10] = (drive[10][0], drive[10][1] + 0.001, 80.0)  # a poor fix mid-trip: never public
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, garage + drive))

    track = _track(client)
    coords = track["geometry"]["coordinates"]
    _assert_far_from(coords, HOME)
    assert len(coords) == len(track["properties"]["times"]) == 16  # drive fixes 4..20 minus the poor one
    assert all(lon == pytest.approx(HOME[1]) for lon, _ in coords)


def test_trip_that_never_leaves_home_has_no_public_track(client, seed, fixture_batch):
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, [(HOME[0], HOME[1], 5.0)] + _jitter(40)))
    assert _track(client)["geometry"]["coordinates"] == []
    assert client.get("/api/live").json()["devices"] == []


def test_trip_stuck_in_live_is_trimmed_at_both_ends(client, seed, fixture_batch, dbname):
    # The Stop message never came and the processor hasn't closed the trip yet: status is still
    # 'live', but 20 minutes of silence mean it has ended, so its end is private too.
    old = dt.datetime.now(UTC) - dt.timedelta(minutes=20)
    fixes = [(HOME[0], HOME[1], 5.0)] + _drive(19) + [(HOME[0] + 19 * STEP_DEG, HOME[1], 7.0)] * 30
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, fixes, start=old - dt.timedelta(minutes=2)),
         received_at=old)

    assert client.get(f"/api/sessions/{SID}").json()["status"] == "live"
    coords = _track(client)["geometry"]["coordinates"]
    end = (HOME[0] + 19 * STEP_DEG, HOME[1])
    _assert_far_from(coords, HOME)
    _assert_far_from(coords, end)
    assert len(coords) == 12  # drive fixes 4..15

    # Events: only the one in the public middle is served and counted.
    start = old - dt.timedelta(minutes=2)
    for i in (2, 10, 18):
        _insert_event(dbname, SID, start + dt.timedelta(seconds=2 * i + 0.5), HOME[0] + i * STEP_DEG, HOME[1])
    (ev,) = client.get(f"/api/sessions/{SID}/events").json()["features"]
    assert ev["geometry"]["coordinates"][1] == pytest.approx(HOME[0] + 10 * STEP_DEG)
    (s,) = client.get("/api/sessions").json()["sessions"]
    assert s["eventCounts"]["pothole"] == 1


def test_stop_received_counts_as_ended_even_if_batches_are_missing(client, seed, fixture_batch):
    # The Stop copy says 25 batches, only 20 arrived: the processor keeps status 'live' for now.
    seed(meta=[session_meta(SID)], batches=_trip_north(fixture_batch, 20))
    seed(meta=[session_meta(SID, batchCount=25, endedAtUtc="2026-11-21T09:30:00.000Z")])

    s = client.get(f"/api/sessions/{SID}").json()
    assert s["status"] == "live"
    assert len(_track(client)["geometry"]["coordinates"]) == 12  # both ends trimmed
    assert client.get("/api/live").json()["devices"] == []  # its position is its endpoint


def test_live_device_hidden_when_back_home(client, seed, fixture_batch):
    out_and_back = [(HOME[0], HOME[1], 5.0)] + _drive(10) + list(reversed(_drive(10)))[1:] + [(HOME[0], HOME[1], 5.0)]
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, out_and_back))
    assert client.get("/api/live").json()["devices"] == []
    # /track of a live trip only trims its start (API.md); its end zone is trimmed once it has ended.
    assert len(_track(client)["geometry"]["coordinates"]) > 0


def test_live_track_is_the_last_two_minutes(client, seed, fixture_batch):
    n = 150  # 5 minutes, one fix every 2 s
    fixes = [(HOME[0], HOME[1], 5.0)] + _drive(n - 1)
    seed(meta=[session_meta(SID)], batches=_batches(fixture_batch, fixes))
    (dev,) = client.get("/api/live").json()["devices"]
    assert 59 <= len(dev["track"]) <= 61
    assert dev["track"][-1][1] == pytest.approx(HOME[0] + (n - 1) * STEP_DEG)


def _trip_north(fixture_batch, n):
    return _batches(fixture_batch, [(HOME[0], HOME[1], 5.0)] + _drive(n - 1))


def test_segment_passes_in_a_private_zone_are_not_served(client, seed, fixture_batch, dbname):
    """Defense in depth for the finalize job's in_privacy_zone flag (a path length, like the old trim)."""
    import psycopg

    start = dt.datetime.now(UTC) - dt.timedelta(minutes=5)
    seed(meta=[session_meta(SID), session_meta(SID, batchCount=20, endedAtUtc="2026-11-21T09:30:00.000Z")],
         batches=_batches(fixture_batch, [(HOME[0], HOME[1], 5.0)] + _drive(19), start=start))
    cells = {"8b1e00000000fff": 0, "8b1e00000001fff": 10}  # at home, and mid-trip
    with psycopg.connect(dbname=dbname, autocommit=True) as conn:
        for idx, (h3, i) in enumerate(cells.items()):
            lat = HOME[0] + i * STEP_DEG
            conn.execute(
                "INSERT INTO segments (h3, center, boundary) VALUES (%s, "
                "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, "
                "ST_Buffer(ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 20))",
                (h3, HOME[1], lat, HOME[1], lat))
            conn.execute(
                "INSERT INTO segment_observations (session_id, pass_idx, h3, t_start, duration_s, aw_rms,"
                " n_windows, in_privacy_zone) VALUES (%s, %s, %s, %s, 1.5, 0.3, 7, false)",
                (SID, idx, h3, start + dt.timedelta(seconds=2 * i + 0.2)))

    home = client.get("/api/segments/8b1e00000000fff")
    assert home.status_code == 200 and home.json()["observations"] == []
    (obs,) = client.get("/api/segments/8b1e00000001fff").json()["observations"]
    assert obs["sessionId"] == SID
