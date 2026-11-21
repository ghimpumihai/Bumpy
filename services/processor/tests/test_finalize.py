"""The finalize job and the session-ready notifier.

Unit tests need nothing; the integration tests (a real PostGIS) stream a trip through the live path,
finalize it from a local copy of the raw archive and check that a clean trip gives the live numbers
again, that a rerun changes nothing, and that the aggregates are rebuilt."""

import gzip
import json
import math

import numpy as np
import pytest

from conftest import motion_batch, requires_db

from roadride import finalize as fz
from roadride.dsp import SeriesPoint
from roadride.live import parse_batch, parse_session

T0 = 1_795_000_000.0


# --- Messages -------------------------------------------------------------------------------

def test_parse_message_from_the_processor_and_from_event_grid():
    assert fz.parse_message(b'{"sessionId": "abc", "reason": "trip_end"}') == ("live", "abc")
    grid = {"eventType": "Microsoft.Storage.BlobCreated",
            "subject": "/blobServices/default/containers/sessions/blobs/abc-123/_complete.json"}
    assert fz.parse_message(json.dumps(grid).encode()) == ("upload", "abc-123")
    assert fz.parse_message(json.dumps([grid]).encode()) == ("upload", "abc-123")
    assert fz.parse_message(b"not json") == ("invalid", None)
    assert fz.parse_message(b'{"subject": "/containers/sessions/blobs/x/data.csv"}') == ("invalid", None)


def test_unsupported_and_unknown_messages_are_dead_lettered(tmp_path):
    archive = fz.DirArchive(tmp_path)
    grid = b'{"subject": "/blobServices/default/containers/sessions/blobs/abc/_complete.json"}'
    assert fz.handle(None, archive, grid)[0] == "dead_letter"
    assert fz.handle(None, archive, b"[]")[0] == "dead_letter"


# --- The raw archive ------------------------------------------------------------------------

class _ContentEncodingGzipClient:
    """Stands in for the SDK's ContainerClient on a blob ingest wrote with Content-Encoding: gzip:
    download_blob inflates it unless decompress=False."""

    def __init__(self, blobs: dict[str, bytes]):
        self.blobs = blobs

    def list_blobs(self, name_starts_with: str):
        return [type("Blob", (), {"name": n})() for n in sorted(self.blobs) if n.startswith(name_starts_with)]

    def download_blob(self, name: str, decompress: bool = True):
        data = self.blobs[name]
        out = gzip.decompress(data) if decompress else data
        return type("Downloader", (), {"readall": lambda self: out})()


def test_blob_archive_returns_the_stored_gzip_not_the_inflated_json(batch, session_meta):
    sid = batch["sessionId"]
    blobs = {f"raw/session={sid}/00000000.json.gz": gzip.compress(json.dumps(batch).encode()),
             f"raw/session={sid}/session-start.json.gz": gzip.compress(json.dumps(session_meta).encode())}
    archive = object.__new__(fz.BlobArchive)
    archive._client = _ContentEncodingGzipClient(blobs)
    trip = fz.load_trip(archive, sid)
    assert [b.batch_seq for b in trip.batches] == [batch["batchSeq"]]
    assert trip.meta and trip.meta[0]["sessionId"] == sid


# --- Segment passes -------------------------------------------------------------------------

def _series(n, speed=10.0, start=T0):
    return [SeriesPoint(t=start + 0.2 * (k + 1), a_vert=0.0, a_lat=0.0, a_lon=0.0, speed=speed, msdv=0.0,
                        rough_rms=1.0 + (k % 2), dose_inc=0.04 * 0.2) for k in range(n)]


def _band_cell(lat, lon):
    return f"cell{int(lat * 10_000)}"  # a new "cell" every 0.0001° of latitude (≈ 11 m)


def test_passes_follow_the_cells_and_carry_roughness_dose_and_potholes():
    series = _series(100)  # 20 s
    fixes = [(T0 + s, 46.0 + 0.0001 * s, 23.0) for s in range(0, 21)]  # 1 cell per second
    passes = fz.build_passes(series, fixes, [T0 + 5.5], cell_of=_band_cell)
    assert 19 <= len(passes) <= 21
    assert sum(p.n_windows for p in passes) == 100
    full = [p for p in passes if p.n_windows == 5]
    assert full and all(p.duration_s == pytest.approx(1.0) for p in full)
    assert all(p.roughness_rms == pytest.approx(math.sqrt((1 + 4 + 1 + 4 + 1) / 5), rel=0.2) for p in full)
    assert all(p.aw_rms == pytest.approx(0.2) for p in passes)
    assert sum(p.pothole_count for p in passes) == 1
    assert all(p.mean_speed_ms == 10.0 for p in passes)


def test_no_position_without_nearby_fixes():
    series = _series(100)
    fixes = [(T0, 46.0, 23.0), (T0 + 1, 46.0001, 23.0), (T0 + 19, 46.0019, 23.0), (T0 + 20, 46.002, 23.0)]
    passes = fz.build_passes(series, fixes, [], cell_of=_band_cell)
    covered = sum(p.n_windows for p in passes)
    assert covered < 40  # the 18 s hole between fixes has no position, so no passes


def test_slow_pass_has_no_roughness():
    passes = fz.build_passes(_series(10, speed=0.3), [(T0, 46, 23), (T0 + 3, 46, 23)], [],
                             cell_of=_band_cell)
    (p,) = passes
    assert p.roughness_rms is None and p.mean_speed_ms == pytest.approx(0.3)


def test_invalid_windows_do_not_count_for_roughness():
    series = _series(10)
    fixes = [(T0, 46, 23), (T0 + 3, 46, 23)]
    invalid = np.zeros(10, dtype=bool)
    invalid[:4] = True  # the first 4 windows (roughness 1, 2, 1, 2) were handled
    (p,) = fz.build_passes(series, fixes, [], cell_of=_band_cell, invalid=invalid)
    assert p.roughness_rms == pytest.approx(math.sqrt((1 + 4 + 1 + 4 + 1 + 4) / 6))
    assert p.n_windows == 10 and p.aw_rms == pytest.approx(0.2)  # the dose still counts
    invalid[:] = True
    (p,) = fz.build_passes(series, fixes, [], cell_of=_band_cell, invalid=invalid)
    assert p.roughness_rms is None and p.mean_speed_ms == 10.0


def test_real_h3_cells_at_resolution_11():
    import h3

    series = _series(50)
    fixes = [(T0 + s, 46.77 + 0.0001 * s, 23.62) for s in range(0, 11)]
    passes = fz.build_passes(series, fixes, [])
    assert passes and all(h3.get_resolution(p.h3) == 11 for p in passes)


def test_stream_quality():
    q = fz.stream_quality([0.0, 0.01, 0.02, 2.0, 2.01], 100.0)
    assert q["rows"] == 5 and q["gapsOver1s"] == 1 and q["maxGapS"] == pytest.approx(1.98)


# --- One pass equals the live path ----------------------------------------------------------

def _vert(pothole_at):
    rng = np.random.default_rng(5)
    noise = rng.normal(0, 0.3, 200_000)

    def vert(t):
        idx = np.clip(((t - T0) * 100).astype(int), 0, len(noise) - 1)
        return 0.8 * np.sin(2 * np.pi * 0.2 * t) + noise[idx] + 15.0 * np.exp(-((t - pothole_at) / 0.01) ** 2)
    return vert


def test_run_pipeline_matches_the_stream_processors_batch_by_batch_state(batch):
    """What store.Store._process_signal does per batch (state through JSON between batches) and
    one finalize pass over the same batches must agree."""
    from roadride.dsp import Pipeline

    vert = _vert(T0 + 21.0)
    facts = [parse_batch(motion_batch(batch, "s1", seq, T0 + 2 * seq, vert)) for seq in range(30)]
    state, live_series, live_msdv = None, [], 0.0
    for f in facts:
        p = Pipeline(json.loads(json.dumps(state)) if state else None)
        out = p.feed(np.asarray(f.motion_t), np.asarray(f.motion_ua).reshape(-1, 3),
                     np.asarray(f.motion_g).reshape(-1, 3),
                     [(x.t.timestamp() - f.clock_offset, x.speed_ms) for x in f.fixes])
        live_series += [(round(s.t + f.clock_offset, 6), s.a_vert) for s in out.series]
        live_msdv, state = out.msdv, p.to_state()

    sig = fz.run_pipeline(facts)
    assert [(round(s.t, 6), s.a_vert) for s in sig.series] == live_series
    assert sig.msdv == pytest.approx(live_msdv, rel=1e-9)
    assert len(sig.events) == 1 and sig.resets == 0


def test_missing_batch_restarts_the_filters(batch):
    vert = _vert(T0 + 999)
    facts = [parse_batch(motion_batch(batch, "s1", seq, T0 + 2 * seq, vert)) for seq in (0, 1, 2, 4, 5)]
    assert fz.run_pipeline(facts).resets == 1


# --- Integration ----------------------------------------------------------------------------

def _gz(doc) -> bytes:
    return gzip.compress(json.dumps(doc).encode())


def _write_archive(root, sid, batches, metas=()):
    folder = root / "raw" / f"session={sid}"
    folder.mkdir(parents=True, exist_ok=True)
    for b in batches:
        (folder / f"{b['batchSeq']:08d}.json.gz").write_bytes(_gz(b))
    for m in metas:
        phase = "stop" if "batchCount" in m else "start"
        (folder / f"session-{phase}.json.gz").write_bytes(_gz(m))


def _stream(db, batches, metas):
    """The live path: what the stream processor writes for these messages."""
    import datetime as dt

    from roadride.store import Store

    s = Store(db)
    received = dt.datetime.fromtimestamp(T0, dt.timezone.utc)
    with db.transaction():
        s.apply_session(parse_session(metas[0]))
        for b in batches:
            s.apply_batch(parse_batch(b), received)
        for m in metas[1:]:
            s.apply_session(parse_session(m))
    return s


def _trip(batch, session_meta, sid, n=30, **meta_extra):
    batches = [motion_batch(batch, sid, seq, T0 + 2 * seq, _vert(T0 + 21.0)) for seq in range(n)]
    for b in batches:
        b["deviceId"] = session_meta["deviceId"]
    start = dict(session_meta, sessionId=sid, **meta_extra)
    stop = dict(start, batchCount=n, endedAtUtc="2026-11-20T10:00:00.000Z")
    return batches, [start, stop]


def _one(db, sql, *args):
    return db.execute(sql, args).fetchone()


@requires_db
def test_finalize_reproduces_a_clean_live_trip_and_aggregates_it(db, batch, session_meta, tmp_path):
    sid = "trip-clean"
    batches, metas = _trip(batch, session_meta, sid)
    store = _stream(db, batches, metas)
    assert store.ended == [sid]
    live = db.execute("SELECT t, a_vert, msdv FROM session_series WHERE session_id = %s ORDER BY t",
                      (sid,)).fetchall()
    live_events = db.execute("SELECT type, t FROM events ORDER BY t").fetchall()
    live_msdv = _one(db, "SELECT msdv_z FROM sessions")[0]

    _write_archive(tmp_path, sid, batches, metas)
    assert fz.handle(db, fz.DirArchive(tmp_path), json.dumps({"sessionId": sid}).encode()) == ("complete", sid)

    final = db.execute("SELECT t, a_vert, msdv FROM session_series WHERE session_id = %s ORDER BY t",
                       (sid,)).fetchall()
    assert [(t, round(a, 6)) for t, a, _ in final] == [(t, round(a, 6)) for t, a, _ in live]
    assert db.execute("SELECT type, t FROM events ORDER BY t").fetchall() == live_events
    status, incomplete, quality, include, reasons, msdv, valid, finalized = _one(
        db, "SELECT status, incomplete, quality_status, include_in_agg, exclusion_reasons, msdv_z, "
            "valid_fraction, finalized_at IS NOT NULL FROM sessions")
    assert (status, incomplete, quality, include, reasons) == ("complete", False, "ok", True, [])
    assert msdv == pytest.approx(live_msdv, rel=1e-9) and valid > 0.9 and finalized

    assert _one(db, "SELECT count(*) FROM segment_observations")[0] > 10
    method, n_sessions = _one(db, "SELECT method, n_sessions FROM aggregation_fit")
    assert (method, n_sessions) == ("percentile", 1)  # one trip can't fit the model
    assert _one(db, "SELECT count(*) FROM segment_agg WHERE vehicle_type = 'all'")[0] == \
        _one(db, "SELECT count(DISTINCT h3) FROM segment_observations")[0]
    assert _one(db, "SELECT count(*) FROM segment_agg WHERE vehicle_type = 'bus'")[0] > 0
    assert _one(db, "SELECT bool_and(ST_NPoints(boundary::geometry) = 7) FROM segments")[0]

    # A redelivered message rewrites the same rows.
    counts = _one(db, "SELECT (SELECT count(*) FROM session_series), (SELECT count(*) FROM events), "
                      "(SELECT count(*) FROM segment_observations), (SELECT count(*) FROM segment_agg)")
    assert fz.handle(db, fz.DirArchive(tmp_path), json.dumps({"sessionId": sid}).encode())[0] == "complete"
    assert _one(db, "SELECT (SELECT count(*) FROM session_series), (SELECT count(*) FROM events), "
                    "(SELECT count(*) FROM segment_observations), (SELECT count(*) FROM segment_agg)") == counts

    # The phone's backlog after finalize reopens the trip; the next finalize includes it.
    import datetime as dt

    from roadride.store import Store
    db.execute("UPDATE sessions SET ready_sent_at = now()")
    late = motion_batch(batch, sid, 30, T0 + 60, _vert(T0 + 999))
    late["deviceId"] = session_meta["deviceId"]
    store = Store(db)
    with db.transaction():
        assert store.apply_batch(parse_batch(late), dt.datetime.fromtimestamp(T0 + 70, dt.timezone.utc)) == "new"
    assert store.ended == [sid]
    assert _one(db, "SELECT status, ready_sent_at FROM sessions") == ("processing", None)
    assert _one(db, "SELECT count(*) FROM session_series")[0] == counts[0]  # untouched until finalize
    finalized_msdv = _one(db, "SELECT msdv_z FROM sessions")[0]
    later = motion_batch(batch, sid, 31, T0 + 62, _vert(T0 + 999))
    later["deviceId"] = session_meta["deviceId"]
    with db.transaction():
        store.apply_batch(parse_batch(later), dt.datetime.fromtimestamp(T0 + 72, dt.timezone.utc))
    assert _one(db, "SELECT msdv_z FROM sessions")[0] >= finalized_msdv  # the dose continues
    _write_archive(tmp_path, sid, [late, later])
    fz.handle(db, fz.DirArchive(tmp_path), json.dumps({"sessionId": sid}).encode())
    assert _one(db, "SELECT status FROM sessions")[0] == "complete"
    assert _one(db, "SELECT count(*) FROM session_series")[0] > counts[0]


@requires_db
def test_finalize_from_the_archive_alone_and_with_a_missing_batch(db, batch, session_meta, tmp_path):
    sid = "trip-gap"
    batches, metas = _trip(batch, session_meta, sid)
    del batches[10]
    _write_archive(tmp_path, sid, batches, metas)  # nothing reached the database live
    summary = fz.finalize_session(db, fz.DirArchive(tmp_path), sid)
    assert summary["batches"] == 29
    status, incomplete, quality, ctx, vehicle = _one(
        db, "SELECT status, incomplete, quality_status, context_known, vehicle_type FROM sessions")
    assert (status, incomplete, quality, ctx, vehicle) == ("complete", True, "degraded", True, "bus")
    q = _one(db, "SELECT quality FROM sessions")[0]
    assert q["missingBatches"] == 1 and q["filterRestarts"] == 1
    assert q["streams"]["deviceMotion"]["gapsOver1s"] == 1


@requires_db
def test_replay_is_finalized_but_never_aggregated(db, batch, session_meta, tmp_path):
    sid = "trip-replay"
    batches, metas = _trip(batch, session_meta, sid, replayOf="orig", source="replay")
    for b in batches:
        b["source"] = "replay"
    _write_archive(tmp_path, sid, batches, metas)
    fz.handle(db, fz.DirArchive(tmp_path), json.dumps({"sessionId": sid}).encode())
    assert _one(db, "SELECT status, include_in_agg, exclusion_reasons FROM sessions") == \
        ("complete", False, ["replay"])
    assert _one(db, "SELECT n_sessions FROM aggregation_fit")[0] == 0
    assert _one(db, "SELECT count(*) FROM segment_agg")[0] == 0


@requires_db
def test_no_archive_is_dead_lettered_and_not_resent(db, tmp_path):
    from roadride import ready

    db.execute("INSERT INTO sessions (session_id, status) VALUES ('nothing', 'processing')")
    db.commit()
    assert fz.handle(db, fz.DirArchive(tmp_path), b'{"sessionId": "nothing"}')[0] == "dead_letter"
    assert ready.due(db) == []  # parked: the sweeper doesn't resend it every 45 minutes


@requires_db
def test_stop_copy_after_the_idle_close_reopens_the_trip(db, batch, session_meta):
    from roadride.store import Store

    batches, (start, stop) = _trip(batch, session_meta, "late-stop", n=3)
    _stream(db, batches, [start])
    db.execute("UPDATE sessions SET status = 'complete', ready_sent_at = now()")
    db.commit()
    store = Store(db)
    with db.transaction():
        store.apply_session(parse_session(stop))
    assert _one(db, "SELECT status, ready_sent_at, expected_batch_count FROM sessions") == ("processing", None, 3)
    with db.transaction():  # a retried Stop copy doesn't reopen it again
        db.execute("UPDATE sessions SET status = 'complete'")
        store.apply_session(parse_session(stop))
    assert _one(db, "SELECT status FROM sessions")[0] == "complete"


@requires_db
def test_ready_sweep_sends_once_and_closes_silent_trips(db, batch, session_meta):
    import psycopg

    from roadride import ready

    _stream(db, *_trip(batch, session_meta, "ended", n=3))
    silent, _ = _trip(batch, session_meta, "silent", n=3)
    _stream(db, silent, [dict(session_meta, sessionId="silent")])
    db.execute("UPDATE sessions SET last_received_at = now() - interval '20 minutes' WHERE session_id = 'silent'")
    db.commit()

    sent = []
    with psycopg.connect(dbname=db.info.dbname, autocommit=True) as conn:
        assert sorted(ready.sweep(conn, sent.append)) == ["ended", "silent"]
        assert ready.sweep(conn, sent.append) == []  # already sent
    assert sorted(json.loads(b)["sessionId"] for b in sent) == ["ended", "silent"]
    assert _one(db, "SELECT status, incomplete FROM sessions WHERE session_id = 'silent'") == ("processing", True)
    assert _one(db, "SELECT status, incomplete FROM sessions WHERE session_id = 'ended'") == ("processing", False)


def _label(b, rel, typ):
    b["labels"] = b.get("labels", []) + [{"t": rel, "type": typ, "value": None, "note": None}]


@requires_db
def test_finalize_scores_detections_and_marks_handled_and_drifting_windows(db, batch, session_meta, tmp_path):
    """Pothole at 21 s (tapped 0.8 s later), a speed bump tap with no detection, the phone handled
    at 50 s (a jolt there is not a pothole) and tilted 30° in its mount for 4 s from 32 s."""
    sid = "trip-checks"
    jolt = _vert(T0 + 21.0)
    vert = lambda t: jolt(t) + 15.0 * np.exp(-((t - (T0 + 51.0)) / 0.01) ** 2)  # noqa: E731
    batches = [motion_batch(batch, sid, seq, T0 + 2 * seq, vert) for seq in range(30)]
    for b in batches:
        b["deviceId"] = session_meta["deviceId"]
    _label(batches[10], 1.8, "pothole")
    _label(batches[20], 0.5, "speed_bump")
    _label(batches[25], 0.0, "phone_moved")
    tilt = math.radians(30)
    for b in batches[16:18]:
        b["deviceMotion"]["g_y"] = [math.sin(tilt)] * 200
        b["deviceMotion"]["g_z"] = [-math.cos(tilt)] * 200
    start = dict(session_meta, sessionId=sid)
    _write_archive(tmp_path, sid, batches, [start, dict(start, batchCount=30)])
    fz.finalize_session(db, fz.DirArchive(tmp_path), sid)

    events = db.execute("SELECT type, t, matched_label FROM events").fetchall()
    assert [(typ, round(t.timestamp() - T0), m) for typ, t, m in events] == [("pothole", 21, True)]
    q = _one(db, "SELECT quality FROM sessions")[0]
    assert q["detection"]["pothole"] == {"truePositives": 1, "falsePositives": 0, "falseNegatives": 0,
                                         "precision": 1.0, "recall": 1.0}
    assert q["detection"]["speed_bump"]["falseNegatives"] == 1
    inv = q["invalidSeconds"]
    assert inv["phone_moved"] == pytest.approx(10, abs=0.4)
    assert inv["gravity_drift"] == pytest.approx(4, abs=1.0)
    assert inv["gyro_gps_mismatch"] == 0
    valid, status = _one(db, "SELECT valid_fraction, quality_status FROM sessions")
    assert valid == pytest.approx(1 - 14 / 60, abs=0.03)
    assert status == "degraded"  # 10 s of 60 handled: over the 10 % limit
    # Handled or tilted windows don't count for roughness; their passes still exist.
    rough_windows = _one(db, "SELECT sum(n_windows) FILTER (WHERE roughness_rms IS NOT NULL) FROM segment_observations")[0]
    all_windows = _one(db, "SELECT sum(n_windows) FROM segment_observations")[0]
    assert all_windows - rough_windows >= 50


def test_a_window_is_placed_at_its_middle():
    """A series point's t is its window's end; placing the window there shifted every pass by half a
    window. Lat grows 1° per second here, and the cell boundary is at t = 1.15 s."""
    series = [SeriesPoint(t=0.2 * (k + 1), a_vert=0.0, a_lat=0.0, a_lon=0.0, speed=10.0, msdv=0.0)
              for k in range(10)]
    fixes = [(float(s), float(s), 0.0) for s in range(4)]
    passes = fz.build_passes(series, fixes, [], cell_of=lambda lat, lon: "A" if lat < 1.15 else "B")
    # Windows ending at 0.2 … 1.2 s have their middles at 0.1 … 1.1 s, all before the boundary.
    assert [(p.h3, p.n_windows) for p in passes] == [("A", 6), ("B", 4)]
