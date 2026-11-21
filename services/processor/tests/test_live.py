import datetime as dt

from roadride.live import exclusion_reasons, parse_batch, parse_session

UTC = dt.timezone.utc


def test_fixture_batch_facts(batch):
    f = parse_batch(batch)
    assert f.session_id == batch["sessionId"] and f.device_id == "FIXTURE-DEVICE"
    assert f.batch_seq == 0 and f.source == "live"
    assert f.t0_utc == dt.datetime(2025, 11, 21, 9, 15, 32, tzinfo=UTC)
    # Newest sample: the location fix at t0 + 0.120 s (columnar samples end at t0 + 0.04 s).
    assert f.end_utc == dt.datetime(2025, 11, 21, 9, 15, 32, 120000, tzinfo=UTC)
    assert f.sample_counts == {"deviceMotion": 5, "accelRaw": 5, "gyroRaw": 5, "altimeter": 1,
                               "audioLevel": 1, "location": 1, "labels": 2}
    (fix,) = f.fixes
    assert (fix.lat, fix.lon, fix.speed_ms, fix.course_deg, fix.h_acc_m) == (46.77121, 23.62363, 8.4, 92, 4.7)
    assert [lab.type for lab in f.labels] == ["pothole", "note"]
    # Label times are relative to t0 as well.
    assert f.labels[0].t == dt.datetime(2025, 11, 21, 9, 15, 32, 40000, tzinfo=UTC)
    assert f.battery == 0.800000011920929 and f.thermal == "nominal" and f.low_power is False


def test_replay_of_comes_from_session_metadata(session_meta):
    assert parse_session(session_meta).replay_of is None
    assert parse_session(dict(session_meta, replayOf="orig")).replay_of == "orig"
    assert parse_session(dict(session_meta, replayOf="")).replay_of is None


def test_minus_one_means_unknown(batch):
    batch["location"][0].update(speed=-1, course=-1)
    batch["device"]["battery"] = -1
    f = parse_batch(batch)
    assert f.fixes[0].speed_ms is None and f.fixes[0].course_deg is None
    assert f.battery is None


def test_batch_without_samples_ends_at_t0(batch):
    for block in ("deviceMotion", "accelRaw", "gyroRaw", "altimeter", "audioLevel"):
        batch[block] = {k: [] for k in batch[block]}
    batch["location"], batch["labels"] = [], []
    f = parse_batch(batch)
    assert f.end_utc == f.t0_utc and f.last_fix is None


def test_replay_source_and_unknown_source(batch):
    batch["source"] = "replay"
    assert parse_batch(batch).source == "replay"
    batch["source"] = "something-new"
    assert parse_batch(batch).source == "live"


def test_session_start_and_stop(session_meta):
    s = parse_session(session_meta)
    assert s.phase == "start" and s.vehicle_type == "bus" and s.vehicle_line == "24"
    assert s.started_at == dt.datetime(2025, 11, 21, 9, 15, 30, tzinfo=UTC) and s.ended_at is None

    session_meta.update(batchCount=12, endedAtUtc="2025-11-21T09:45:00.000Z")
    s = parse_session(session_meta)
    assert s.phase == "stop" and s.batch_count == 12
    assert s.ended_at == dt.datetime(2025, 11, 21, 9, 45, tzinfo=UTC)


def test_unknown_vehicle_type(session_meta):
    session_meta["vehicle"]["type"] = "spaceship"
    assert parse_session(session_meta).vehicle_type == "unknown"


def test_exclusion_reasons():
    rigid = {"rigid": True, "handheld": False}
    assert exclusion_reasons("live", "live", True, rigid) == ["live_only"]
    assert exclusion_reasons("live", "complete", True, rigid) == []
    assert exclusion_reasons("upload", "processing", True, rigid) == ["processing"]
    assert exclusion_reasons("replay", "complete", True, rigid) == ["replay"]
    assert exclusion_reasons("live", "live", False, None) == ["live_only", "unknown_context"]
    assert exclusion_reasons("live", "complete", True, {"rigid": False, "handheld": True}) == \
        ["not_rigid", "handheld"]
    assert exclusion_reasons("live", "complete", True, rigid, "bad") == ["bad_quality"]
