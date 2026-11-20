"""Integration tests against a real PostGIS (skipped without PGHOST/PGPASSWORD)."""

import datetime as dt

from conftest import MIGRATIONS, requires_db

from roadride.live import parse_batch, parse_session

pytestmark = requires_db

UTC = dt.timezone.utc
RECEIVED = dt.datetime(2025, 11, 21, 9, 15, 34, tzinfo=UTC)


def _store(db):
    from roadride.store import Store
    return Store(db)


def _one(db, sql, *args):
    return db.execute(sql, args).fetchone()


def _batch(batch, seq, *, fix_t_ms=None, lat=None):
    b = dict(batch, batchSeq=seq)
    b["t0UtcMs"] = batch["t0UtcMs"] + seq * 2000
    b["t0Utc"] = dt.datetime.fromtimestamp(b["t0UtcMs"] / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    loc = dict(batch["location"][0], tUtcMs=fix_t_ms or b["t0UtcMs"] + 120)
    if lat is not None:
        loc["lat"] = lat
    b["location"] = [loc]
    b["labels"] = []
    return parse_batch(b)


def test_migrations_are_idempotent(db):
    from roadride.migrate import apply_migrations
    import psycopg

    with psycopg.connect(dbname=db.info.dbname, autocommit=True) as conn:
        assert apply_migrations(conn, MIGRATIONS) == []
    assert _one(db, "SELECT postgis_version() IS NOT NULL")[0]


def test_first_batch_creates_session_track_labels_and_live_state(db, batch):
    s = _store(db)
    with db.transaction():
        assert s.apply_batch(parse_batch(batch), RECEIVED) == "new"

    sid = batch["sessionId"]
    status, source, reasons, received, last_seq = _one(
        db, "SELECT status, source, exclusion_reasons, received_batches, last_batch_seq "
            "FROM sessions WHERE session_id = %s", sid)
    assert (status, source, received, last_seq) == ("live", "live", 1, 0)
    assert reasons == ["live_only", "unknown_context"]  # no session.json yet

    assert _one(db, "SELECT count(*) FROM track_points WHERE session_id = %s", sid)[0] == 1
    lat, lon = _one(db, "SELECT ST_Y(geom::geometry), ST_X(geom::geometry) FROM track_points")
    assert (round(lat, 5), round(lon, 5)) == (46.77121, 23.62363)
    assert _one(db, "SELECT count(*) FROM labels WHERE session_id = %s", sid)[0] == 2

    row = _one(db, "SELECT session_id, lat, lon, speed_ms, received_at, battery FROM live_state "
                   "WHERE device_id = 'FIXTURE-DEVICE'")
    assert row[0] == sid and (row[1], row[2], row[3]) == (46.77121, 23.62363, 8.4)
    assert row[4] == RECEIVED and abs(row[5] - 0.8) < 1e-6


def test_duplicate_batch_is_counted_not_reapplied(db, batch):
    s = _store(db)
    with db.transaction():
        s.apply_batch(parse_batch(batch), RECEIVED)
        assert s.apply_batch(parse_batch(batch), RECEIVED) == "duplicate"
    assert _one(db, "SELECT received_batches, duplicate_batches FROM sessions")[0:2] == (1, 1)
    assert _one(db, "SELECT count(*) FROM ingest_batches")[0] == 1


def test_late_batch_is_stored_but_does_not_move_live_position(db, batch):
    s = _store(db)
    with db.transaction():
        s.apply_batch(_batch(batch, 0, lat=46.0), RECEIVED)
        s.apply_batch(_batch(batch, 2, lat=46.2), RECEIVED)
        assert s.apply_batch(_batch(batch, 1, lat=46.1), RECEIVED) == "late"
    assert _one(db, "SELECT lat FROM live_state")[0] == 46.2
    assert _one(db, "SELECT count(*) FROM track_points")[0] == 3
    assert _one(db, "SELECT late_batches, last_batch_seq FROM sessions") == (1, 2)


def test_batch_without_fix_keeps_previous_position(db, batch):
    s = _store(db)
    with db.transaction():
        s.apply_batch(_batch(batch, 0, lat=46.5), RECEIVED)
        no_fix = _batch(batch, 1)
        no_fix = no_fix.__class__(**{**no_fix.__dict__, "fixes": []})
        s.apply_batch(no_fix, RECEIVED)
    assert _one(db, "SELECT lat FROM live_state")[0] == 46.5


def test_session_context_then_stop_marks_processing_once_all_batches_are_in(db, batch, session_meta):
    s = _store(db)
    sid = batch["sessionId"]
    with db.transaction():
        assert s.apply_session(parse_session(session_meta)) == "applied"
    assert _one(db, "SELECT vehicle_type, vehicle_line, context_known, exclusion_reasons "
                    "FROM sessions WHERE session_id = %s", sid) == ("bus", "24", True, ["live_only"])

    stop = dict(session_meta, batchCount=2, endedAtUtc="2025-11-21T09:16:00.000Z")
    with db.transaction():
        s.apply_batch(_batch(batch, 0), RECEIVED)
        s.apply_session(parse_session(stop))
    assert _one(db, "SELECT status FROM sessions")[0] == "live"  # batch 1 still missing

    with db.transaction():
        s.apply_batch(_batch(batch, 1), RECEIVED)
    assert _one(db, "SELECT status, expected_batch_count FROM sessions") == ("processing", 2)

    # A Start copy retried after the Stop copy changes nothing.
    with db.transaction():
        assert s.apply_session(parse_session(session_meta)) == "stale_start"
    assert _one(db, "SELECT expected_batch_count, ended_at IS NOT NULL FROM sessions") == (2, True)


def test_replay_never_aggregates(db, batch):
    batch["source"] = "replay"
    s = _store(db)
    with db.transaction():
        s.apply_batch(parse_batch(batch), RECEIVED)
    assert _one(db, "SELECT source, include_in_agg, exclusion_reasons FROM sessions") == \
        ("replay", False, ["replay", "unknown_context"])


def test_checkpoints_roundtrip(db):
    s = _store(db)
    with db.transaction():
        s.save_checkpoint("ingest", "$Default", "0", 41, None)
        s.save_checkpoint("ingest", "$Default", "0", 42, RECEIVED)
        s.save_checkpoint("ingest", "$Default", "1", 7, None)
    assert s.load_checkpoints("ingest", "$Default") == {"0": 42, "1": 7}
