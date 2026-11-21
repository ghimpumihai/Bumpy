"""Tests for the replay tool: batches must pass the real ingest contract and processor parser,
and a replay must arrive whole through the real ingest handler over HTTP.

    pip install pytest && pytest -q tools/replay
"""

from __future__ import annotations

import gzip
import json
import math
import sys
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "services" / "ingest"))
sys.path.insert(0, str(ROOT / "services" / "processor"))

import replay  # noqa: E402
from ingest_core import contract, handler  # noqa: E402
from roadride.live import parse_batch, parse_session  # noqa: E402

HEADERS = json.loads((ROOT / "src/mobile-ios/tools/fixtures/csv_headers.json").read_text())
START_UP = 1000.0  # phone uptime at Start
UTC0 = 1_763_716_532_000  # Unix ms at START_UP
DURATION = 7.3  # seconds of trip -> 4 batches
NOW_MS = 1_800_000_000_000.0


def _row(name: str, t_up: float, values: dict) -> str:
    cols = HEADERS[name].split(",")
    vals = {"t_up": f"{t_up:.6f}", "t_utc_ms": str(round(UTC0 + (t_up - START_UP) * 1000)), **values}
    return ",".join(str(vals.get(c, "")) for c in cols)


@pytest.fixture
def session(tmp_path) -> Path:
    """A session folder in the app's on-disk format (StreamFile headers)."""
    folder = tmp_path / "2025-11-21T09-15-32Z_abcd"
    folder.mkdir()
    rows: dict[str, list[str]] = {n: [] for n in HEADERS}
    n = int(DURATION * 100)
    for i in range(n):
        t = START_UP + i / 100
        rows["device_motion"].append(_row("device_motion", t, {
            "ua_x": "0.000000", "ua_y": "0.000000", "ua_z": f"{0.1 * math.sin(i / 3):.6f}",
            "g_x": "0.000000", "g_y": "0.000000", "g_z": "-1.000000",
            "rr_x": "0.000000", "rr_y": "0.000000", "rr_z": "",  # empty = non-finite on the phone
            "q_w": "1.000000", "q_x": "0.000000", "q_y": "0.000000", "q_z": "0.000000"}))
        rows["accel_raw"].append(_row("accel_raw", t, {"x": "0.0", "y": "0.0", "z": "-1.0"}))
        rows["gyro_raw"].append(_row("gyro_raw", t, {"x": "0.0", "y": "0.0", "z": "0.0"}))
    for s in range(int(DURATION) + 1):
        t = START_UP + s + 0.5
        rows["location"].append(_row("location", t, {
            "lat": f"{46.77 + s * 1e-4:.8f}", "lon": "23.62000000", "alt": "350.0", "h_acc": "4.7",
            "speed": "12.5", "speed_acc": "0.5", "course": "0.0", "is_simulated": "0"}))
        rows["altimeter"].append(_row("altimeter", t, {"rel_alt_m": "0.1", "pressure_kpa": "97.1"}))
    rows["audio_level"] = [_row("audio_level", START_UP + i / 10, {"avg_dbfs": "-40", "peak_dbfs": "-30"})
                           for i in range(int(DURATION * 10))]
    rows["labels"] = [_row("labels", START_UP + 3.2, {"type": "pothole"}),
                      _row("labels", START_UP + 5.0, {"type": "sickness", "value": "2", "note": "a, b"})]
    rows["labels"][1] = rows["labels"][1].replace("a, b", '"a, b"')
    rows["device"] = [_row("device", START_UP, {"battery_level": "0.80", "thermal_state": "fair",
                                                 "low_power": "0"})]
    for name, lines in rows.items():
        (folder / f"{name}.csv").write_text("\n".join([HEADERS[name], *lines]) + "\n")
    # A torn last line, as after a crash.
    with open(folder / "device_motion.csv", "a") as fh:
        fh.write(f"{START_UP + DURATION:.6f},123,0.1")
    meta = json.loads(gzip.decompress(
        (ROOT / "src/mobile-ios/tools/fixtures/session_meta_stop_v1.json.gz").read_bytes()))
    meta.update(sessionId="orig-session", deviceId="PHONE-1", startUptimeSec=START_UP)
    (folder / "session.json").write_text(json.dumps(meta))
    return folder


def _dry_run(session, tmp_path, **kw):
    plan = replay.make_plan(session, now_ms=NOW_MS, **kw)
    out = tmp_path / "out"
    out.mkdir()
    n = replay.run(session, plan, sender=None, dry_run=out, speed=0, send_stop=True, log=lambda _: None)
    batches = [json.loads(gzip.decompress(p.read_bytes())) for p in sorted(out.glob("*_0*.json.gz"))]
    meta = {ph: json.loads(gzip.decompress((out / f"{plan.session_id}_meta-{ph}.json.gz").read_bytes()))
            for ph in ("start", "stop")}
    return plan, n, batches, meta


def test_batches_pass_the_ingest_contract_and_carry_every_sample(session, tmp_path):
    plan, n, batches, meta = _dry_run(session, tmp_path)
    assert n == len(batches) == 4 == plan.windows
    for b in batches:
        contract.validate_batch(b)
    assert [b["batchSeq"] for b in batches] == [0, 1, 2, 3]
    assert {b["sessionId"] for b in batches} == {plan.session_id} and plan.session_id != "orig-session"
    assert {(b["source"], b["deviceId"]) for b in batches} == {("replay", "replay-PHONE-1")}
    # Every complete CSV row lands in exactly one batch; the torn last line is dropped.
    assert sum(len(b["deviceMotion"]["t"]) for b in batches) == int(DURATION * 100)
    assert sum(len(b["location"]) for b in batches) == int(DURATION) + 1
    assert [lab["type"] for b in batches for lab in b["labels"]] == ["pothole", "sickness"]
    sick = batches[2]["labels"][0]
    assert (sick["value"], sick["note"], sick["t"]) == ("2", "a, b", 1.0)
    assert batches[0]["labels"] == [] and batches[1]["labels"][0]["value"] is None
    assert all(v == 0.0 for b in batches for v in b["deviceMotion"]["rr_z"])
    assert batches[0]["device"] == {"battery": 0.8, "thermal": "fair", "lowPower": False}


def test_times_move_to_now_and_stay_consistent(session, tmp_path):
    _, _, batches, _ = _dry_run(session, tmp_path)
    assert batches[0]["t0UtcMs"] == NOW_MS
    assert [b["t0UtcMs"] - NOW_MS for b in batches] == [0, 2000, 4000, 6000]
    assert [b["t0Up"] for b in batches] == [START_UP, START_UP + 2, START_UP + 4, START_UP + 6]
    assert batches[0]["t0Utc"] == replay.iso_ms(NOW_MS)
    # The fix at t_up = START_UP + 0.5 keeps its place relative to the batch start.
    assert batches[0]["location"][0]["tUtcMs"] - batches[0]["t0UtcMs"] == 500
    assert all(0 <= t < 2 for b in batches for t in b["deviceMotion"]["t"])


def test_processor_parses_the_batches(session, tmp_path):
    _, _, batches, meta = _dry_run(session, tmp_path)
    f = parse_batch(batches[1])
    assert f.source == "replay" and f.sample_counts["deviceMotion"] == 200
    assert f.clock_offset == pytest.approx((NOW_MS + 2000) / 1000 - (START_UP + 2))
    s = parse_session(meta["start"])
    assert s.replay_of == "orig-session" and s.phase == "start" and s.vehicle_type == "bus"


def test_session_metadata_frames_the_replay(session, tmp_path):
    plan, n, batches, meta = _dry_run(session, tmp_path)
    assert contract.validate_session_meta(meta["start"], plan.session_id) == "start"
    assert contract.validate_session_meta(meta["stop"], plan.session_id) == "stop"
    assert meta["start"]["endedAtUtc"] is None and "batchCount" not in meta["start"]
    assert meta["stop"]["batchCount"] == n
    assert meta["start"]["startedAtUtc"] == replay.iso_ms(NOW_MS)
    assert replay.parse_iso_ms(meta["stop"]["endedAtUtc"]) >= batches[-1]["t0UtcMs"]
    assert meta["stop"]["replayOf"] == "orig-session" and meta["stop"]["deviceId"] == "replay-PHONE-1"


def test_from_and_duration_cut_the_trip(session, tmp_path):
    plan, n, batches, _ = _dry_run(session, tmp_path, start_offset=2, duration=3)
    assert n == 2 and batches[0]["t0Up"] == START_UP + 2
    assert batches[0]["t0UtcMs"] == NOW_MS
    assert sum(len(b["deviceMotion"]["t"]) for b in batches) == 300
    with pytest.raises(replay.ReplayError):
        replay.make_plan(session, start_offset=60, now_ms=NOW_MS)


def test_command_line_dry_run(session, tmp_path, capsys):
    out = tmp_path / "cli"
    assert replay.main([str(session), "--dry-run", str(out), "--duration", "4"]) == 0
    assert len(list(out.glob("*_0*.json.gz"))) == 2 and len(list(out.glob("*_meta-*.json.gz"))) == 2
    assert "Done: 2 batches" in capsys.readouterr().out
    assert replay.main([str(tmp_path / "missing"), "--dry-run", str(out)]) == 1


def test_zip_export_is_accepted(session, tmp_path):
    z = tmp_path / "export.zip"
    with zipfile.ZipFile(z, "w") as zf:
        for p in session.iterdir():
            zf.write(p, f"{session.name}/{p.name}")
    work = tmp_path / "unzipped"
    work.mkdir()
    assert replay.open_session(z, work).name == session.name


# --- End to end over HTTP, through the real ingest handler ---------------------------------

class _Keys:
    """Like the Key Vault secret {"replay": hash, "PHONE-1": hash, "PHONE-2": hash}."""
    BOUND = {"test-key": {"replay"}, "phone-1-key": {"PHONE-1"}, "phone-2-key": {"PHONE-2"}}

    def identify(self, presented):
        return self.BOUND.get(presented)


class _Sinks:
    def __init__(self):
        self.events: list[tuple[dict, dict]] = []
        self.fail_next = 1  # the first publish fails: the replay must retry

    def publish(self, partition_key, body, properties):
        if self.fail_next:
            self.fail_next -= 1
            raise RuntimeError("event hub down")
        self.events.append((properties, json.loads(body)))

    def archive(self, blob_name, gz_body):
        return True


@pytest.fixture
def ingest_server():
    sinks = _Sinks()

    class H(BaseHTTPRequestHandler):
        def _go(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            hdrs = dict(self.headers.items())
            if self.command == "POST" and self.path == "/api/ingest":
                r = handler.handle_batch(hdrs, raw, _Keys(), sinks)
            elif self.command == "PUT" and self.path.startswith("/api/ingest/sessions/"):
                r = handler.handle_session(self.path.rsplit("/", 1)[1], hdrs, raw, _Keys(), sinks)
            else:
                r = handler.Response(404, {"message": "Not Found"})
            body = json.dumps(r.body).encode()
            self.send_response(r.status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_POST = do_PUT = _go

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", sinks
    srv.shutdown()


def test_replay_arrives_whole_through_the_ingest_function(session, ingest_server):
    url, sinks = ingest_server
    plan = replay.make_plan(session)
    sender = replay.Sender(url, "test-key", log=lambda _: None, sleep=lambda _: None)
    n = replay.run(session, plan, sender=sender, dry_run=None, speed=0, send_stop=True,
                   log=lambda _: None)
    kinds = [(p["kind"], p.get("phase"), p.get("batchSeq")) for p, _ in sinks.events]
    assert kinds == [("session", "start", None)] + [("batch", None, i) for i in range(n)] + \
        [("session", "stop", None)]
    assert sinks.events[-1][1]["batchCount"] == n


def test_real_time_pacing_sends_each_batch_when_its_window_closes(session, ingest_server):
    url, _ = ingest_server
    plan = replay.make_plan(session)
    now = [0.0]
    waits = []

    def sleep(s):
        waits.append(round(s, 6))
        now[0] += s

    sender = replay.Sender(url, "test-key", log=lambda _: None, sleep=lambda _: None)
    replay.run(session, plan, sender=sender, dry_run=None, speed=2, send_stop=True,
               log=lambda _: None, clock=lambda: now[0], sleep=sleep)
    assert waits == [1.0, 1.0, 1.0, 1.0]  # 2 s windows at 2x


class _Recorder:
    """A Sender stand-in that records what was sent, and when (on a fake clock)."""

    def __init__(self, now, interrupt_at=None):
        self.now, self.interrupt_at, self.sent = now, interrupt_at, []

    def send(self, method, path, body, idem):
        b = json.loads(body)
        if self.interrupt_at is not None and b.get("batchSeq") == self.interrupt_at:
            raise KeyboardInterrupt
        self.sent.append((NOW_MS + self.now[0] * 1000, b))


@pytest.mark.parametrize("speed", [0, 1, 4])
def test_no_batch_is_stamped_after_it_is_sent(session, speed):
    plan = replay.make_plan(session, speed=speed, now_ms=NOW_MS)
    now = [0.0]
    rec = _Recorder(now)

    def sleep(s):
        now[0] += s

    replay.run(session, plan, sender=rec, dry_run=None, speed=speed, send_stop=True,
               log=lambda _: None, clock=lambda: now[0], sleep=sleep)
    batches = [(at, b) for at, b in rec.sent if "batchSeq" in b]
    assert all(b["t0UtcMs"] + 2000 <= at + 1 for at, b in batches)
    # ... and the trip ends when its last batch goes out (at real speed: now + its length).
    at, last = batches[-1]
    assert last["t0UtcMs"] + 2000 == pytest.approx(at, abs=1)
    if speed == 1:
        assert batches[0][1]["t0UtcMs"] == NOW_MS


def test_ctrl_c_closes_the_trip_with_what_was_sent(session):
    plan = replay.make_plan(session, now_ms=NOW_MS)
    rec = _Recorder([0.0], interrupt_at=2)
    with pytest.raises(KeyboardInterrupt):
        replay.run(session, plan, sender=rec, dry_run=None, speed=0, send_stop=True, log=lambda _: None)
    stop = rec.sent[-1][1]
    assert stop["batchCount"] == 2 and stop["endedAtUtc"] is not None
    assert [b.get("batchSeq") for _, b in rec.sent] == [None, 0, 1, None]

    # Interrupted before any batch went out: nothing to close.
    rec = _Recorder([0.0], interrupt_at=0)
    with pytest.raises(KeyboardInterrupt):
        replay.run(session, plan, sender=rec, dry_run=None, speed=0, send_stop=True, log=lambda _: None)
    assert [b.get("batchSeq") for _, b in rec.sent] == [None]


def test_wrong_key_stops_at_once(session, ingest_server):
    url, sinks = ingest_server
    plan = replay.make_plan(session)
    sender = replay.Sender(url, "nope", log=lambda _: None, sleep=lambda _: None)
    with pytest.raises(replay.ReplayError, match="401"):
        replay.run(session, plan, sender=sender, dry_run=None, speed=0, send_stop=True,
                   log=lambda _: None)
    assert sinks.events == []


def test_a_phone_key_replays_its_own_trip(session, ingest_server):
    url, sinks = ingest_server
    plan = replay.make_plan(session)  # deviceId replay-PHONE-1
    sender = replay.Sender(url, "phone-1-key", log=lambda _: None, sleep=lambda _: None)
    n = replay.run(session, plan, sender=sender, dry_run=None, speed=0, send_stop=True,
                   log=lambda _: None)
    assert len(sinks.events) == n + 2


def test_another_phones_key_is_refused(session, ingest_server):
    url, sinks = ingest_server
    plan = replay.make_plan(session)
    sender = replay.Sender(url, "phone-2-key", log=lambda _: None, sleep=lambda _: None)
    with pytest.raises(replay.ReplayError, match="403"):
        replay.run(session, plan, sender=sender, dry_run=None, speed=0, send_stop=True,
                   log=lambda _: None)
    assert sinks.events == []
