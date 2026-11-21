"""The stream processor's write path: poison events, connection loss, checkpoints, start positions."""

import binascii
import datetime as dt
import json
import os

import psycopg
import pytest

from conftest import requires_db

from roadride import stream
from roadride.db import is_connection_loss, is_retryable_conflict

UTC = dt.timezone.utc
ENQUEUED = dt.datetime(2025, 11, 21, 9, 15, 35, tzinfo=UTC)


class FakeEvent:
    """What the handlers read from azure.eventhub.EventData."""

    def __init__(self, body: dict, seq: int, *, kind: str = "batch",
                 received: str = "2025-11-21T09:15:34.000Z"):
        self._body = json.dumps(body)
        self.sequence_number = seq
        self.enqueued_time = ENQUEUED + dt.timedelta(seconds=seq)
        self.properties = {b"kind": kind.encode(), b"receivedAtUtc": received.encode()}

    def body_as_str(self, encoding="UTF-8"):
        return self._body


def batch_body(template: dict, seq: int, **changes) -> dict:
    b = dict(template, batchSeq=seq, **changes)
    b["t0UtcMs"] = template["t0UtcMs"] + seq * 2000
    b["location"] = [dict(template["location"][0], tUtcMs=b["t0UtcMs"] + 120)]
    return b


# --- Pure units ------------------------------------------------------------------------------

class _NotBroken:
    broken = False
    closed = False


class _Broken:
    broken = True
    closed = False


@pytest.mark.parametrize("exc, lost", [
    (psycopg.errors.ProgramLimitExceeded("index row size exceeds btree maximum"), False),
    (psycopg.errors.DiskFull("disk full"), False),
    (psycopg.errors.OutOfMemory("out of memory"), False),
    (psycopg.errors.QueryCanceled("statement timeout"), False),
    (psycopg.errors.LockNotAvailable("lock timeout"), False),
    (psycopg.DataError("PostgreSQL text fields cannot contain NUL (0x00) bytes"), False),
    (ValueError("bad json"), False),
    (psycopg.errors.AdminShutdown("terminating connection"), True),
    (psycopg.errors.ConnectionFailure("connection failure"), True),
    (psycopg.OperationalError("server closed the connection unexpectedly"), True),  # no SQLSTATE
])
def test_only_lost_connections_count_as_connection_loss(exc, lost):
    assert is_connection_loss(exc, _NotBroken()) is lost


def test_a_broken_connection_is_always_connection_loss():
    assert is_connection_loss(psycopg.errors.ProgramLimitExceeded("x"), _Broken())


def test_deadlocks_are_retryable_conflicts():
    assert is_retryable_conflict(psycopg.errors.DeadlockDetected("x"))
    assert is_retryable_conflict(psycopg.errors.SerializationFailure("x"))
    assert not is_retryable_conflict(psycopg.errors.ProgramLimitExceeded("x"))


SAVED_AT = dt.datetime(2026, 11, 20, 12, 0, tzinfo=UTC)
CREATED = dt.datetime(2026, 11, 1, tzinfo=UTC)


def _part(begin, last, empty=False):
    return {"beginning_sequence_number": begin, "last_enqueued_sequence_number": last,
            "is_empty": empty}


def test_resume_after_a_valid_checkpoint():
    assert stream.resume_position((500, SAVED_AT), _part(100, 900), CREATED) == (500, None)
    assert stream.resume_position((900, SAVED_AT), _part(100, 900), CREATED) == (900, None)  # caught up


def test_resume_never_read_partition_from_the_start():
    assert stream.resume_position(None, _part(0, 10), CREATED) == ("-1", None)


def test_resume_checkpoint_beyond_the_last_event_means_a_new_hub():
    position, warning = stream.resume_position((500, SAVED_AT), _part(0, 42), CREATED)
    assert position == "-1" and "beyond" in warning
    position, warning = stream.resume_position((500, SAVED_AT), _part(0, -1, empty=True), CREATED)
    assert position == "-1" and warning


def test_resume_hub_created_after_the_checkpoint_means_a_new_hub():
    # The new hub already has more events than the old checkpoint number: only the date tells.
    recreated = SAVED_AT + dt.timedelta(hours=1)
    position, warning = stream.resume_position((500, SAVED_AT), _part(0, 9000), recreated)
    assert position == "-1" and "recreated" in warning


def test_resume_after_expired_events_warns_and_reads_the_earliest():
    position, warning = stream.resume_position((500, SAVED_AT), _part(800, 900), CREATED)
    assert position == "-1" and "expired" in warning


def test_read_up_to_waits_for_every_partition_and_takes_the_oldest():
    w = stream.PartitionWriter("ingest", connect_fn=lambda pid: None, partitions=["0", "1"])
    old = dt.datetime.now(UTC) - dt.timedelta(minutes=20)
    assert w.read_up_to() is None  # nothing heard yet (just restarted)
    w._progress["0"] = (old, False)
    assert w.read_up_to() is None  # partition 1 hasn't reported
    w.idle("1")
    assert w.read_up_to() == old  # partition 0 is still 20 minutes behind
    w.idle("0")
    assert dt.datetime.now(UTC) - w.read_up_to() < dt.timedelta(seconds=5)  # read to the end


def test_lag_is_zero_once_caught_up():
    w = stream.PartitionWriter("ingest", connect_fn=lambda pid: None)
    w._progress["0"] = (dt.datetime.now(UTC) - dt.timedelta(seconds=30), False)
    assert 29 < w.lag_seconds()["0"] < 60
    w.idle("0")
    assert w.lag_seconds() == {"0": 0.0}


class _Ctx:
    def __init__(self, pid="0"):
        self.partition_id = pid
        self.checkpoints = []

    def update_checkpoint(self, event=None):
        self.checkpoints.append(event)


class _RecordingWriter:
    def __init__(self, fail=False):
        self.writes, self.idles, self.fail = [], [], fail

    def write(self, pid, events):
        if self.fail:
            raise RuntimeError("not committed")
        self.writes.append((pid, events))

    def idle(self, pid):
        self.idles.append(pid)


def test_sdk_checkpoint_moves_after_each_commit_only():
    writer = _RecordingWriter()
    on_batch, _ = stream.callbacks(writer)
    ctx = _Ctx()
    on_batch(ctx, ["e1", "e2"])
    on_batch(ctx, [])
    assert ctx.checkpoints == ["e2"] and writer.idles == ["0"]

    failing = _RecordingWriter(fail=True)
    on_batch, _ = stream.callbacks(failing)
    ctx = _Ctx()
    with pytest.raises(RuntimeError):
        on_batch(ctx, ["e3"])
    assert ctx.checkpoints == []  # the SDK reads these events again


# --- Against PostGIS -------------------------------------------------------------------------

@pytest.fixture
def writer(db):
    connections = []

    def connect_fn(pid):
        conn = psycopg.connect(dbname=db.info.dbname)
        connections.append(conn)
        return conn

    w = stream.PartitionWriter("ingest", connect_fn=connect_fn)
    w.connections = connections
    yield w
    for c in connections:
        c.close()


def _one(db, sql, *args):
    row = db.execute(sql, args).fetchone()
    db.rollback()  # end the read so later reads see later commits
    return row


def _checkpoint(db):
    return _one(db, "SELECT sequence_number FROM stream_checkpoints WHERE partition_id = '0'")


@requires_db
def test_poison_event_is_skipped_and_the_rest_commits(db, writer, batch):
    sid = batch["sessionId"]
    huge = binascii.hexlify(os.urandom(3000)).decode()  # too big for a btree index row
    events = [
        FakeEvent(batch_body(batch, 0), 10),
        FakeEvent(batch_body(batch, 0, sessionId=huge), 11),  # ProgramLimitExceeded
        FakeEvent(batch_body(batch, 1), 12),
        FakeEvent(batch_body(batch, 2), 13),
    ]
    writer.write("0", events)
    assert _one(db, "SELECT received_batches FROM sessions WHERE session_id = %s", sid) == (3,)
    assert _one(db, "SELECT count(*) FROM sessions") == (1,)
    assert _checkpoint(db) == (13,)
    assert len(writer.connections) == 1  # no reconnect for a poison event


@requires_db
def test_unparseable_event_is_skipped(db, writer, batch):
    bad = FakeEvent({}, 20)
    bad._body = "{not json"
    writer.write("0", [bad, FakeEvent(batch_body(batch, 0), 21)])
    assert _one(db, "SELECT received_batches FROM sessions") == (1,)
    assert _checkpoint(db) == (21,)


@requires_db
def test_a_bad_label_drops_only_the_labels(db, writer, batch):
    body = batch_body(batch, 0)
    body["labels"] = [dict(batch["labels"][0], note="bad\x00note")]  # DataError: NUL in text
    writer.write("0", [FakeEvent(body, 30), FakeEvent(batch_body(batch, 1, labels=[]), 31)])
    sid = batch["sessionId"]
    assert _one(db, "SELECT received_batches FROM sessions WHERE session_id = %s", sid) == (2,)
    assert _one(db, "SELECT count(*) FROM ingest_batches") == (2,)
    assert _one(db, "SELECT count(*) FROM track_points") == (2,)
    assert _one(db, "SELECT count(*) FROM labels") == (0,)
    assert _one(db, "SELECT count(*) FROM live_state") == (1,)
    assert _checkpoint(db) == (31,)


@requires_db
def test_a_transient_conflict_is_retried_not_skipped(db, writer, batch, monkeypatch):
    real = stream.handle_event
    calls = {"n": 0}

    def flaky(store, event):
        calls["n"] += 1
        if calls["n"] == 1:
            raise psycopg.errors.DeadlockDetected("deadlock detected")
        return real(store, event)

    monkeypatch.setattr(stream, "handle_event", flaky)
    writer.write("0", [FakeEvent(batch_body(batch, 0), 40)])
    assert calls["n"] == 2
    assert _one(db, "SELECT received_batches FROM sessions") == (1,)


def _terminate(db, conn):
    pid = conn.info.backend_pid
    with psycopg.connect(dbname="postgres", autocommit=True) as admin:
        admin.execute("SELECT pg_terminate_backend(%s)", (pid,))


@requires_db
def test_connection_loss_reconnects_and_retries(db, batch, monkeypatch):
    monkeypatch.setattr(stream, "RETRY_DELAY_S", 0)
    made = []

    def connect_fn(pid):
        conn = psycopg.connect(dbname=db.info.dbname)
        if not made:
            _terminate(db, conn)  # the first connection dies before it is used
        made.append(conn)
        return conn

    w = stream.PartitionWriter("ingest", connect_fn=connect_fn)
    w.write("0", [FakeEvent(batch_body(batch, 0), 50), FakeEvent(batch_body(batch, 1), 51)])
    assert len(made) == 2
    assert _one(db, "SELECT received_batches FROM sessions") == (2,)
    assert _checkpoint(db) == (51,)
    for c in made:
        c.close()


class _Exited(Exception):
    pass


def _fake_exit(code):
    raise _Exited(code)


@requires_db
def test_connection_that_stays_lost_exits_without_committing(db, batch, monkeypatch):
    monkeypatch.setattr(stream, "RETRY_DELAY_S", 0)
    monkeypatch.setattr(stream.os, "_exit", _fake_exit)
    made = []

    def connect_fn(pid):
        conn = psycopg.connect(dbname=db.info.dbname)
        _terminate(db, conn)
        made.append(conn)
        return conn

    w = stream.PartitionWriter("ingest", connect_fn=connect_fn)
    with pytest.raises(_Exited) as exited:
        w.write("0", [FakeEvent(batch_body(batch, 0), 60)])
    assert exited.value.args == (1,) and len(made) == stream.WRITE_ATTEMPTS
    assert _one(db, "SELECT count(*) FROM sessions") == (0,)
    assert _checkpoint(db) is None
    for c in made:
        c.close()


@requires_db
def test_failed_connect_goes_through_the_retry_path(db, batch, monkeypatch):
    monkeypatch.setattr(stream, "RETRY_DELAY_S", 0)
    monkeypatch.setattr(stream.os, "_exit", _fake_exit)
    attempts = []

    def connect_fn(pid):
        attempts.append(pid)
        raise psycopg.OperationalError("could not get an Entra token")

    w = stream.PartitionWriter("ingest", connect_fn=connect_fn)
    with pytest.raises(_Exited):
        w.write("0", [FakeEvent(batch_body(batch, 0), 70)])
    assert len(attempts) == stream.WRITE_ATTEMPTS


@requires_db
def test_failure_outside_the_savepoints_rolls_back_and_raises(db, writer, batch, monkeypatch):
    from roadride.store import Store

    def broken_checkpoint(self, *args):
        raise psycopg.errors.ProgramLimitExceeded("checkpoint row too large")

    monkeypatch.setattr(Store, "save_checkpoint", broken_checkpoint)
    with pytest.raises(psycopg.errors.ProgramLimitExceeded):
        writer.write("0", [FakeEvent(batch_body(batch, 0), 80)])
    assert _one(db, "SELECT count(*) FROM sessions") == (0,)  # nothing without its checkpoint


@requires_db
def test_processor_replay_is_not_a_phone_duplicate(db, writer, batch):
    events = [FakeEvent(batch_body(batch, 0), 90), FakeEvent(batch_body(batch, 1), 91)]
    writer.write("0", events)
    writer.write("0", events)  # the same events again, e.g. after a restart
    assert _one(db, "SELECT received_batches, duplicate_batches FROM sessions") == (2, 0)

    retry = FakeEvent(batch_body(batch, 1), 92, received="2025-11-21T09:15:50.000Z")
    writer.write("0", [retry])  # the phone sent batch 1 again: a new ingest receipt
    assert _one(db, "SELECT received_batches, duplicate_batches FROM sessions") == (2, 1)


def _parse(body):
    from roadride.live import parse_batch
    return parse_batch(body)


@requires_db
def test_trip_end_notifies_after_the_commit(db, batch, session_meta):
    kicked = []
    w = stream.PartitionWriter("ingest", connect_fn=lambda pid: psycopg.connect(dbname=db.info.dbname),
                               on_trip_end=lambda: kicked.append(_one(db, "SELECT status FROM sessions")))
    stop = dict(session_meta, batchCount=1, endedAtUtc="2025-11-21T09:16:00.000Z")
    w.write("0", [FakeEvent(batch_body(batch, 0), 110)])
    assert kicked == []
    w.write("0", [FakeEvent(stop, 111, kind="session")])
    assert kicked == [("processing",)]  # the notifier sees the committed row
    for c in w._conns.values():
        c.close()
