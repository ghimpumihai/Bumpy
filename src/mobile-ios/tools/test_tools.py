#!/usr/bin/env python3
"""test_tools.py: stdlib unittest suite for quick_check.py and mock_ingest_server.py.

Usage:
    python3 -I src/mobile-ios/tools/test_tools.py -v

Both tools are run as subprocesses (exactly as the team runs them), with the same interpreter.
  - quick_check: synthetic session folders (valid and deliberately broken) in a temp dir: rates,
    headers, UTC anchors, rows before the session start, stream coverage, stats.durationSec, and
    pre-D48 audio files/keys in older folders (ignored, one INFO line).
  - quick_check as a module (imported by path): the header contract: if
    tools/fixtures/csv_headers.json exists (written by the Swift unit tests from StreamFile.header),
    quick_check.EXPECTED_HEADER_LINES must equal it exactly.
  - mock_ingest_server: started on a free port, exercised over HTTP, always terminated.
  - contract test: if tools/fixtures/ingest_batch_v1.json.gz exists (written by the Swift unit
    tests from the app's real IngestBatch encoder), it is POSTed unchanged and must get 201.
Python 3.9+, stdlib only.
"""

import datetime as dt
import gzip
import http.client
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
QUICK_CHECK = os.path.join(HERE, "quick_check.py")
MOCK_SERVER = os.path.join(HERE, "mock_ingest_server.py")
FIXTURE = os.path.join(HERE, "fixtures", "ingest_batch_v1.json.gz")
HEADERS_FIXTURE = os.path.join(HERE, "fixtures", "csv_headers.json")
KEY = "test-device-key"

# ----------------------------------------------------------------------------------------------
# Synthetic session folders (headers must match SessionFiles.swift / quick_check.EXPECTED_HEADERS;
# audio_level / audio_segments: quick_check.LEGACY_HEADERS, written only by builds before D48)
# ----------------------------------------------------------------------------------------------

HEADERS = {
    "device_motion": "t_up,t_utc_ms,ua_x,ua_y,ua_z,g_x,g_y,g_z,rr_x,rr_y,rr_z,q_w,q_x,q_y,q_z,"
                     "roll,pitch,yaw",
    "accel_raw": "t_up,t_utc_ms,x,y,z",
    "gyro_raw": "t_up,t_utc_ms,x,y,z",
    "mag_raw": "t_up,t_utc_ms,x,y,z",
    "location": "t_up,t_utc_ms,lat,lon,alt,ell_alt,h_acc,v_acc,speed,speed_acc,course,course_acc,"
                "is_simulated",
    "heading": "t_up,t_utc_ms,mag_heading,true_heading,heading_acc,x,y,z",
    "altimeter": "t_up,t_utc_ms,rel_alt_m,pressure_kpa",
    "abs_altitude": "t_up,t_utc_ms,altitude_m,accuracy_m,precision_m",
    "activity": "t_up,t_utc_ms,stationary,walking,running,automotive,cycling,unknown,confidence,"
                "start_utc_ms",
    "audio_level": "t_up,t_utc_ms,avg_dbfs,peak_dbfs",
    "audio_segments": "t_up,t_utc_ms,event,file",
    "device": "t_up,t_utc_ms,battery_level,battery_state,thermal_state,low_power,free_disk_bytes,"
              "net_status,net_type",
    "labels": "t_up,t_utc_ms,type,value,note",
    "clock": "t_up,t_utc_ms,source",
}

T0_UP = 5000.0
DURATION = 30.0


def iso(ms):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000.0)) + ".%03dZ" % (int(ms) % 1000)


def fake_m4a(n=4096):
    """Bytes standing in for a pre-D48 audio file: an 'ftyp' box and no index. quick_check must
    not open it."""
    return b"\x00\x00\x00\x18ftypM4A \x00\x00\x00\x00M4A isom" + b"\x00" * n


def make_session(folder, gyro_gap=None, location_header=None, utc_offset_ms=0, legacy_meta=False,
                 empty_altimeter=False, pre=None, until=None, recovered=False, stats=None,
                 legacy_audio=False):
    """Writes a ~30 s session that passes every quick_check rule unless a knob breaks it.
    pre:      {stem: [seconds before start, ...]} extra rows prepended (t_up/t_utc_ms before start)
    until:    {stem: seconds} the stream stops after that many seconds
    recovered: session.json as rewritten by crash recovery (recovered=true, endedAtUtc null)
    stats:    session.json "stats" object (None = null, as before the session ends)
    legacy_audio: also write what a build before D48 recorded: audio_level.csv, audio_segments.csv,
              audio_000.m4a / audio_001.m4a (no MP4 index), clock.csv audio_start rows and
              session.json audioEnabled / requestedRatesHz.audioLevel"""
    os.makedirs(folder)
    u0 = int(time.time() * 1000) - 120_000  # wall clock at T0_UP, 2 minutes ago
    pre, until = pre or {}, until or {}

    def utc(t):
        return int(round(u0 + (t - T0_UP) * 1000.0))

    def write(name, rows, header=None):
        with open(os.path.join(folder, name + ".csv"), "w", newline="", encoding="utf-8") as fh:
            fh.write((header or HEADERS[name]) + "\n")
            for r in rows:
                fh.write(r + "\n")

    def ticks(hz, start=0.0, end=DURATION):
        n = int(round((end - start) * hz))
        return [T0_UP + start + i / hz for i in range(n)]

    def stream(name, hz, fmt, times=None):
        ts = times if times is not None else ticks(hz, end=until.get(name, DURATION))
        ts = [T0_UP - s for s in sorted(pre.get(name, []), reverse=True)] + ts
        write(name, [fmt(i, t) for i, t in enumerate(ts)],
              header=location_header if name == "location" else None)

    seg_files = ["audio_000.m4a", "audio_001.m4a"] if legacy_audio else []
    seg_t = {f: T0_UP + 0.2 + i * DURATION / len(seg_files) for i, f in enumerate(seg_files)}
    clock = [f"{T0_UP:.6f},{utc(T0_UP)},start"]
    for f in seg_files:
        clock.append(f"{seg_t[f]:.6f},{utc(seg_t[f])},audio_start")
    for k in range(1, int(DURATION // 10) + 1):
        t = T0_UP + 10 * k
        clock.append(f"{t:.6f},{utc(t)},periodic")
    write("clock", sorted(clock))

    stream("device_motion", 100, lambda i, t: f"{t:.6f},{utc(t) + utc_offset_ms},0.001,-0.002,0.003,"
                                              f"0.0,0.0,-1.0,0.01,0.02,0.03,1.0,0.0,0.0,0.0,0.0,0.0,0.0")
    stream("accel_raw", 100, lambda i, t: f"{t:.6f},{utc(t)},0.0,0.0,-1.0")
    gyro = ticks(100)
    if gyro_gap:
        a, b = gyro_gap
        gyro = [t for t in gyro if not (T0_UP + a < t < T0_UP + b)]
    stream("gyro_raw", 100, lambda i, t: f"{t:.6f},{utc(t)},0.01,0.02,0.03", times=gyro)
    stream("mag_raw", 50, lambda i, t: f"{t:.6f},{utc(t)},10.0,20.0,-30.0")
    stream("location", 1, lambda i, t: f"{t:.6f},{utc(t)},{46.77121 + i * 1e-5:.8f},23.62363000,352.1,"
                                       f"390.2,4.7,3.0,8.4,0.5,92.0,10.0,0")
    stream("heading", 1, lambda i, t: f"{t:.6f},{utc(t)},91.0,95.0,5.0,10.0,20.0,-30.0")
    stream("altimeter", 1, lambda i, t: f"{t:.6f},{utc(t)},0.1,96.5",
           times=[] if empty_altimeter else None)
    stream("abs_altitude", 1, lambda i, t: f"{t:.6f},{utc(t)},352.0,5.0,1.0")
    stream("activity", 1, lambda i, t: f"{t:.6f},{utc(t)},0,0,0,1,0,0,2,{utc(t) - 1000}",
           times=[T0_UP + 1])
    if legacy_audio:
        stream("audio_level", 10, lambda i, t: f"{t:.6f},{utc(t)},-40.5,-20.1")
    stream("device", 0.2, lambda i, t: f"{t:.6f},{utc(t)},0.82,unplugged,nominal,0,50000000000,"
                                       f"satisfied,wifi")
    labels = [
        f"{T0_UP + 5:.6f},{utc(T0_UP + 5)},pothole,,",
        f"{T0_UP + 10:.6f},{utc(T0_UP + 10)},speed_bump,,",
        # multi-line quoted note with a comma and an escaped quote: must count as ONE label
        f'{T0_UP + 15:.6f},{utc(T0_UP + 15)},note,,"first line, with comma\nsecond ""line"""',
    ]
    write("labels", labels)
    if legacy_audio:
        seg_rows = []
        for f in seg_files:
            seg_rows.append(f"{seg_t[f]:.6f},{utc(seg_t[f])},start,{f}")
            with open(os.path.join(folder, f), "wb") as fh:
                fh.write(fake_m4a())
        write("audio_segments", seg_rows)

    meta = {
        "sessionId": str(uuid.uuid4()).upper(),
        "appVersion": "1.0.0 (test)",
        "device": {"model": "iPhone15,2", "name": "iPhone 14 Pro", "iosVersion": "18.1"},
        "timezone": "Europe/Bucharest",
        "startedAtUtc": iso(u0),
        "startUptimeSec": T0_UP,
        "endedAtUtc": None if recovered else iso(utc(T0_UP + DURATION)),
        "vehicle": {"type": "car", "makeModel": "Test Car", "line": None, "notes": ""},
        "mount": {"location": "taped flat on center console", "phoneOrientation": "screen up",
                  "rigid": True, "handheld": False, "seatOverAxle": False, "photoFile": None},
        "people": {"operatorSeat": "front passenger", "raterSeat": "rear left",
                   "raterPosture": "seated", "passengerCount": 2, "raterName": ""},
        "conditions": {"weather": "dry", "notes": ""},
        "requestedRatesHz": {"deviceMotion": 100, "accel": 100, "gyro": 100, "mag": 50},
        "recovered": recovered,
        "syntheticSensors": False,
        "folderName": os.path.basename(folder),
        "deviceId": str(uuid.uuid4()).upper(),
        "preflight": {"completedAtUtc": iso(u0 - 5000), "overridden": False, "checks": []},
        "stats": stats,
    }
    if recovered:
        meta["recoveredAtUtc"] = iso(u0 + 600_000)
    if legacy_audio:
        meta["audioEnabled"] = True
        meta["requestedRatesHz"]["audioLevel"] = 10
    if legacy_meta:
        del meta["vehicle"]["line"]
        del meta["mount"]["handheld"]
        del meta["mount"]["seatOverAxle"]
        del meta["people"]["raterPosture"]
    with open(os.path.join(folder, "session.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
    return folder


def patch_meta(folder, **changes):
    p = os.path.join(folder, "session.json")
    with open(p, encoding="utf-8") as fh:
        meta = json.load(fh)
    meta.update(changes)
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(meta, fh)
    return meta


def run_quick_check(folder):
    p = subprocess.run([sys.executable, "-I", QUICK_CHECK, folder], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=60)
    return p.returncode, p.stdout.decode("utf-8", errors="replace")


class QuickCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="qc-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def session(self, name, **kw):
        return make_session(os.path.join(self.tmp, name), **kw)

    def assertRan(self, out):
        self.assertNotIn("Traceback", out, out)
        self.assertRegex(out, r"(?m)^OVERALL: (PASS|WARN|FAIL)", out)

    def assertFail(self, folder, *needles):
        code, out = run_quick_check(folder)
        self.assertRan(out)
        self.assertEqual(code, 1, out)
        self.assertIn("OVERALL: FAIL", out)
        fails = [ln for ln in out.splitlines() if "[FAIL]" in ln or ln.strip().startswith("FAIL:")]
        for n in needles:
            self.assertTrue(any(n in ln for ln in fails), f"no FAIL line containing {n!r}:\n{out}")
        return out

    def test_valid_session_passes(self):
        code, out = run_quick_check(self.session("valid"))
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertIn("OVERALL: PASS", out)
        self.assertIn("rows=3", out)  # labels: the multi-line note counts once
        self.assertIn("people.raterPosture", out)

    def test_new_session_without_audio_is_clean(self):
        """D48: the app records no audio; nothing about audio is expected or reported."""
        code, out = run_quick_check(self.session("current"))
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertIn("OVERALL: PASS  (0 fail, 0 warn)", out)
        self.assertNotIn("[INFO]", out)
        self.assertNotIn("audio", out.lower())
        self.assertNotIn("D48", out)

    def test_pre_d48_folder_with_audio_is_info_not_fail(self):
        """A folder from a build before D48 still has audio files, CSVs and keys: one INFO line,
        no WARN/FAIL, even when those files are broken (no MP4 index, a 0-byte file, a wrong
        header, a row before the start, a short row, audio stats that disagree)."""
        folder = self.session("oldaudio", legacy_audio=True,
                              stats={"durationSec": DURATION, "audioFiles": ["audio_000.m4a"],
                                     "audioFilesIncomplete": ["audio_000.m4a"]})
        with open(os.path.join(folder, "audio.m4a"), "wb"):
            pass  # 0 bytes
        with open(os.path.join(folder, "audio_level.csv"), "w", encoding="utf-8") as fh:
            fh.write("t_up,t_utc_ms,avg\n1.0,1000,-40\ngarbage\n")  # bad header, row in 1970
        code, out = run_quick_check(folder)
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertIn("OVERALL: PASS  (0 fail, 0 warn)", out)
        infos = [ln for ln in out.splitlines() if "[INFO]" in ln]
        self.assertEqual(len(infos), 1, out)
        for needle in ("from an app build before D48 (no audio), ignored", "audio.m4a",
                       "audio_000.m4a", "audio_001.m4a", "audio_level.csv", "audio_segments.csv",
                       "2 clock.csv row(s) with source=audio_start", "session.json audioEnabled",
                       "requestedRatesHz.audioLevel", "stats.audioFiles",
                       "stats.audioFilesIncomplete"):
            self.assertIn(needle, infos[0])
        # the derived audio_start rows are not used as clock anchors
        self.assertIn("anchors=4 ", out)

    def test_gyro_gap_half_second_fails(self):
        self.assertFail(self.session("gap", gyro_gap=(10.0, 10.5)), "gyro_raw: ", "max gap 0.5")

    def test_wrong_location_header_fails_without_crash(self):
        bad = HEADERS["location"].replace("is_simulated", "is_sim")
        out = self.assertFail(self.session("hdr", location_header=bad),
                              "location.csv: header mismatch")
        self.assertIn("is_simulated", out)
        # later sections still ran
        self.assertIn("== labels.csv ==", out)
        self.assertIn("== summary ==", out)

    def test_utc_offset_500ms_fails(self):
        self.assertFail(self.session("utc", utc_offset_ms=500), "device_motion: t_utc_ms")

    def test_utc_offset_50ms_warns(self):
        code, out = run_quick_check(self.session("utc50", utc_offset_ms=50))
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"\[WARN\] device_motion: t_utc_ms")

    def test_zero_row_altimeter_warns(self):
        code, out = run_quick_check(self.session("noalt", empty_altimeter=True))
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertIn("[WARN] altimeter.csv: header only, 0 data rows", out)

    def test_zero_row_gyro_fails(self):
        folder = self.session("nogyro")
        with open(os.path.join(folder, "gyro_raw.csv"), "w") as fh:
            fh.write(HEADERS["gyro_raw"] + "\n")
        self.assertFail(folder, "gyro_raw: only 0 data rows")

    def test_legacy_session_json_is_info_not_warn(self):
        code, out = run_quick_check(self.session("legacy", legacy_meta=True))
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertIn("OVERALL: PASS", out)
        self.assertIn("[INFO] session.json: no vehicle.line (older app version)", out)

    def test_handheld_warns(self):
        folder = self.session("hand")
        p = os.path.join(folder, "session.json")
        with open(p) as fh:
            meta = json.load(fh)
        meta["mount"]["handheld"] = True
        with open(p, "w") as fh:
            json.dump(meta, fh)
        code, out = run_quick_check(folder)
        self.assertEqual(code, 0, out)
        self.assertIn("excluded from roughness by the backend", out)

    def test_garbage_files_never_crash(self):
        folder = self.session("garbage")
        with open(os.path.join(folder, "session.json"), "w") as fh:
            fh.write('{"sessionId": "x", "preflight": [1], "mount": "nope", "audioEnabled": "yes"}')
        with open(os.path.join(folder, "device_motion.csv"), "wb") as fh:
            fh.write(b"t_up,t_utc_ms\n\x00\x00garbage\n")
        os.remove(os.path.join(folder, "clock.csv"))
        code, out = run_quick_check(folder)
        self.assertRan(out)
        self.assertEqual(code, 1, out)

    # -- helpers for the timeline checks ---------------------------------------------------------

    def run_ok(self, folder):
        """Runs quick_check, expects exit 0 (PASS or WARN); returns (out, warn lines, info lines)."""
        code, out = run_quick_check(folder)
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        lines = out.splitlines()
        return (out, [ln for ln in lines if "[WARN]" in ln], [ln for ln in lines if "[INFO]" in ln])

    def assertLine(self, lines, out, *needles):
        self.assertTrue(any(all(n in ln for n in needles) for ln in lines),
                        f"no line containing all of {needles!r}:\n{out}")

    def assertNoLine(self, lines, out, needle):
        self.assertFalse(any(needle in ln for ln in lines), f"unexpected line with {needle!r}:\n{out}")

    # -- 1. rows before the session start --------------------------------------------------------

    def test_location_cached_fix_within_5s_is_info(self):
        out, warns, infos = self.run_ok(self.session("cached", pre={"location": [3.0]}))
        self.assertIn("OVERALL: PASS", out)
        self.assertLine(infos, out, "location.csv: 1 row(s) up to 5 s before session start")
        self.assertNoLine(warns, out, "before session start")

    def test_location_older_than_5s_before_start_warns(self):
        out, warns, infos = self.run_ok(self.session("stale", pre={"location": [8.0, 2.0]}))
        self.assertLine(warns, out, "location.csv: 1 row(s) more than 5 s before session start",
                        "earliest -8.0 s")
        self.assertLine(infos, out, "location.csv: 1 row(s) up to 5 s before session start")

    def test_prestart_rows_in_other_stream_warn(self):
        out, warns, _ = self.run_ok(self.session("preheading", pre={"heading": [2.5, 1.0]}))
        self.assertLine(warns, out, "heading.csv: 2 row(s) before session start", "earliest -2.5 s")

    def test_prestart_activity_is_exempt(self):
        out, warns, _ = self.run_ok(self.session("preact", pre={"activity": [60.0]}))
        self.assertIn("OVERALL: PASS", out)
        self.assertIn("activity.csv: 1 row(s) before session start (earliest -60.0 s) - expected", out)
        self.assertNoLine(warns, out, "before session start")

    # -- 2. stream coverage ----------------------------------------------------------------------

    def test_gps_that_stops_after_one_second_warns(self):
        out, warns, _ = self.run_ok(self.session("gps1s", until={"location": 2.0}))
        self.assertLine(warns, out, "location covers only 1 s of 30 s session")

    def test_coverage_not_checked_for_sessions_under_30s(self):
        folder = self.session("short", until={"location": 2.0})
        started = dt.datetime.fromisoformat(patch_meta(folder)["startedAtUtc"].replace("Z", "+00:00"))
        ended = started + dt.timedelta(seconds=20)  # a 20 s session
        patch_meta(folder, endedAtUtc=ended.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")
        out, warns, _ = self.run_ok(folder)
        self.assertIn("session duration: 20.0 s", out)
        self.assertNoLine(warns, out, "covers only")

    # -- 3. duration consistency -----------------------------------------------------------------

    def test_finished_duration_matches(self):
        out, warns, _ = self.run_ok(self.session("dur", stats={"durationSec": DURATION + 1.5}))
        self.assertIn("OVERALL: PASS", out)
        self.assertIn("[PASS] session.json: stats.durationSec 31.5 s vs endedAtUtc", out)

    def test_finished_duration_mismatch_warns(self):
        out, warns, _ = self.run_ok(self.session("durbad", stats={"durationSec": DURATION + 10}))
        self.assertLine(warns, out, "stats.durationSec 40.0 s vs endedAtUtc - startedAtUtc 30.0 s",
                        "diff +10.0 s")

    def test_recovered_duration_matches_last_row(self):
        out, warns, _ = self.run_ok(self.session("recok", recovered=True,
                                                 stats={"durationSec": DURATION - 0.01}))
        self.assertIn("[PASS] session.json: stats.durationSec 30.0 s vs last row t_up", out)

    def test_recovered_duration_mismatch_warns(self):
        out, warns, _ = self.run_ok(self.session("recdur", recovered=True,
                                                 stats={"durationSec": 12.0}))
        self.assertLine(warns, out, "stats.durationSec 12.0 s vs last row t_up - startUptimeSec 30.0 s")


def load_quick_check():
    spec = importlib.util.spec_from_file_location("quick_check", QUICK_CHECK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class QuickCheckModuleTests(unittest.TestCase):
    """quick_check imported as a module (by path): schema pinning."""

    @classmethod
    def setUpClass(cls):
        cls.qc = load_quick_check()

    def test_headers_match_swift_fixture(self):
        if not os.path.exists(HEADERS_FIXTURE):
            self.skipTest(f"{os.path.relpath(HEADERS_FIXTURE, HERE)} missing - it is written by the "
                          f"Swift unit tests from StreamFile.header (xcodebuild ... "
                          f"-only-testing:SensorRecorderTests test); header contract not checked")
        with open(HEADERS_FIXTURE, encoding="utf-8") as fh:
            swift = json.load(fh)
        self.assertEqual(self.qc.EXPECTED_HEADER_LINES, swift,
                         "quick_check.EXPECTED_HEADERS differs from the app's StreamFile headers")

    def test_synthetic_session_headers_match_quick_check(self):
        self.assertEqual(HEADERS, self.qc.EXPECTED_HEADER_LINES)
        self.assertEqual(len(self.qc.EXPECTED_HEADER_LINES), 14)


# ----------------------------------------------------------------------------------------------
# Mock ingest server
# ----------------------------------------------------------------------------------------------

class MockServer:
    def __init__(self, *args):
        self.log = tempfile.NamedTemporaryFile(prefix="mock-ingest-", suffix=".log", delete=False)
        self.proc = subprocess.Popen([sys.executable, "-I", MOCK_SERVER, "--host", "127.0.0.1",
                                      "--port", "0"] + list(args),
                                     stdout=self.log, stderr=subprocess.STDOUT)
        self.port = None
        deadline = time.time() + 10
        while time.time() < deadline and self.proc.poll() is None:
            m = re.search(r"http://127\.0\.0\.1:(\d+)", self.output())
            if m:
                self.port = int(m.group(1))
                break
            time.sleep(0.05)
        if self.port is None:
            out = self.output()
            self.stop()
            raise RuntimeError(f"mock server did not start:\n{out}")

    def output(self):
        with open(self.log.name, encoding="utf-8", errors="replace") as fh:
            return fh.read()

    def stop(self):
        """SIGTERM (prints the summary), then SIGKILL as a last resort. Returns the full output."""
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        out = self.output()
        self.log.close()
        try:
            os.unlink(self.log.name)
        except OSError:
            pass
        return out

    def request(self, method, path, body=b"", headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            r = conn.getresponse()
            data = r.read()
            try:
                payload = json.loads(data.decode("utf-8")) if data else None
            except ValueError:
                payload = data
            return r.status, payload
        finally:
            conn.close()

    def ingest(self, batch=None, raw=None, key=KEY, encoding="gzip", idem=True, extra=None):
        if raw is None:
            raw = gzip.compress(json.dumps(batch).encode("utf-8"))
        h = {"Content-Type": "application/json"}
        if encoding is not None:  # None: no Content-Encoding header at all
            h["Content-Encoding"] = encoding
        if key is not None:
            h["x-device-key"] = key
        if idem and isinstance(batch, dict) and "sessionId" in batch:
            h["x-idempotency-key"] = f"{batch['sessionId']}:{batch.get('batchSeq')}"
        h.update(extra or {})
        return self.request("POST", "/api/ingest", raw, h)

    def put_meta(self, meta=None, raw=None, session_id=None, key=KEY, encoding="gzip", idem=True,
                 extra=None):
        """PUT /api/ingest/sessions/<id> (spec §6.1). The path id defaults to the body's sessionId
        and the idempotency key to the phase the body implies (meta-stop iff batchCount)."""
        sid = session_id or (meta or {}).get("sessionId")
        if raw is None:
            raw = gzip.compress(json.dumps(meta).encode("utf-8"))
        h = {"Content-Type": "application/json"}
        if encoding is not None:  # None: no Content-Encoding header at all
            h["Content-Encoding"] = encoding
        if key is not None:
            h["x-device-key"] = key
        if idem and isinstance(meta, dict):
            h["x-idempotency-key"] = f"{sid}:meta-{'stop' if 'batchCount' in meta else 'start'}"
        h.update(extra or {})
        return self.request("PUT", f"/api/ingest/sessions/{sid}", raw, h)


def make_batch(seq=0, n=3, session_id=None):
    t = [round(i * 0.01, 6) for i in range(n)]
    v = [0.001 * (i + 1) for i in range(n)]
    return {
        "schemaVersion": 1,
        "sessionId": session_id or str(uuid.uuid4()).upper(),
        "deviceId": "8C3F1A2B-0000-4000-8000-000000000001",
        "batchSeq": seq,
        "t0Utc": "2026-11-21T09:15:32.120Z",
        "t0Up": 123532.408211,
        "units": {"accel": "g", "gyro": "rad/s", "speed": "m/s", "pressure": "kPa"},
        "deviceMotion": dict({"t": t}, **{c: v for c in ("ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z",
                                                          "rr_x", "rr_y", "rr_z", "q_w", "q_x",
                                                          "q_y", "q_z")}),
        "accelRaw": {"t": t, "x": v, "y": v, "z": v},
        "gyroRaw": {"t": t, "x": v, "y": v, "z": v},
        "location": [{"tUtcMs": 1763716532120, "lat": 46.77121, "lon": 23.62363, "alt": 352.1,
                      "hAcc": 4.7, "speed": 8.4, "speedAcc": 0.5, "course": 92.0}] if n else [],
        "altimeter": {"t": t[:1], "relAltM": v[:1], "pressureKpa": [96.5][:len(t[:1])]},
        "labels": [{"t": 0.01, "type": "pothole", "value": None, "note": None}] if n else [],
        "device": {"battery": 0.82, "thermal": "nominal", "lowPower": False},
    }


def make_meta(session_id=None, batch_count=None, recovered=False, ended=True):
    """session.json as SessionMetadata.swift encodes it (spec §3.8). batch_count set = Stop copy."""
    m = {
        "sessionId": session_id or str(uuid.uuid4()).upper(),
        "appVersion": "1.0.0 (abc1234)",
        "device": {"model": "iPhone15,2", "name": "iPhone 14 Pro", "iosVersion": "18.1"},
        "timezone": "Europe/Bucharest",
        "startedAtUtc": "2026-11-21T09:12:03.512Z",
        "startUptimeSec": 123456.789012,
        "endedAtUtc": None,
        "vehicle": {"type": "bus", "makeModel": "Solaris Urbino", "line": "24", "notes": ""},
        "mount": {"location": "taped flat on floor", "phoneOrientation": "screen up", "rigid": True,
                  "handheld": False, "seatOverAxle": False, "photoFile": None},
        "people": {"operatorSeat": "front", "raterSeat": "rear left", "raterPosture": "standing",
                   "passengerCount": 30, "raterName": ""},
        "conditions": {"weather": "dry", "notes": ""},
        "requestedRatesHz": {"deviceMotion": 100, "accel": 100, "gyro": 100, "mag": 50},
        "recovered": recovered,
        "syntheticSensors": False,
        "folderName": "2026-11-21T09-12-03Z_abcd",
        "deviceId": "8C3F1A2B-0000-4000-8000-000000000001",
        "stats": None,
    }
    if batch_count is not None:
        m["batchCount"] = batch_count
        if ended:
            m["endedAtUtc"] = "2026-11-21T10:02:41.007Z"
    return m


class MockIngestServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = MockServer("--key", KEY)

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()

    def assertStatus(self, got, expected):
        status, payload = got
        self.assertEqual(status, expected, f"payload: {payload}")
        return payload

    def test_valid_then_repeat_is_200_by_default(self):
        b = make_batch(seq=7)
        self.assertStatus(self.srv.ingest(b), 201)
        p = self.assertStatus(self.srv.ingest(b), 200)
        self.assertTrue(p.get("duplicate"))

    def test_wrong_key_is_401(self):
        self.assertStatus(self.srv.ingest(make_batch(), key="wrong"), 401)
        self.assertStatus(self.srv.ingest(make_batch(), key=None), 401)

    def test_key_is_checked_before_body(self):
        self.assertStatus(self.srv.ingest(raw=b"not gzip", key="wrong", encoding="br"), 401)

    def test_gzip_is_decided_by_magic_bytes_not_content_encoding(self):
        # As the ingest function: the Functions host may inflate the body and drop the header (02 §5).
        for enc in ("gzip", "x-gzip", "identity", None):
            with self.subTest(enc=enc, body="gzip"):
                self.assertStatus(self.srv.ingest(make_batch(), encoding=enc), 201)
            with self.subTest(enc=enc, body="already inflated"):
                b = make_batch()
                self.assertStatus(self.srv.ingest(b, raw=json.dumps(b).encode(), encoding=enc), 201)
        p = self.assertStatus(self.srv.ingest(raw=b"\x8b\x0b\x80brotli?", encoding="br"), 400)
        self.assertIn("neither gzip", p["error"])

    def test_strings_the_database_cant_store_are_400(self):
        for name, mutate in (
                ("label type 4 KB", lambda b: b["labels"].append({"t": 1, "type": "x" * 4096, "value": None, "note": None})),
                ("note NUL", lambda b: b["labels"].append({"t": 1, "type": "note", "value": None, "note": "a\x00b"})),
                ("deviceId 129", lambda b: b.update(deviceId="D" * 129)),
                ("vehicle-like free text over 2000", lambda b: b["device"].update(thermal="t" * 2001))):
            with self.subTest(name):
                b = make_batch()
                mutate(b)
                self.assertStatus(self.srv.ingest(b), 400)
        b = make_batch()
        b["labels"].append({"t": 1, "type": "note", "value": None, "note": "n" * 2000})
        self.assertStatus(self.srv.ingest(b), 201)

    def test_multiple_gzip_members_and_trailing_data_rejected(self):
        body = gzip.compress(json.dumps(make_batch()).encode())
        p = self.assertStatus(self.srv.ingest(raw=body + gzip.compress(b"{}")), 400)
        self.assertIn("multiple gzip members", p["error"])
        p = self.assertStatus(self.srv.ingest(raw=body + b"junk"), 400)
        self.assertIn("trailing data", p["error"])
        self.assertStatus(self.srv.ingest(raw=body[:-5]), 400)

    def test_nan_rejected(self):
        raw = gzip.compress(json.dumps(make_batch()).replace('"t0Up": 123532.408211',
                                                             '"t0Up": NaN').encode())
        p = self.assertStatus(self.srv.ingest(raw=raw), 400)
        self.assertIn("invalid JSON", p["error"])

    def test_schema_version_float_or_bool_rejected(self):
        for v in (1.0, True, 2, "1"):
            with self.subTest(v=v):
                b = make_batch()
                b["schemaVersion"] = v
                p = self.assertStatus(self.srv.ingest(b), 400)
                self.assertIn("schemaVersion", p["error"])

    def test_float_tutcms_rejected(self):
        b = make_batch()
        b["location"][0]["tUtcMs"] = 1763716532120.5
        p = self.assertStatus(self.srv.ingest(b), 400)
        self.assertIn("tUtcMs", p["error"])

    def test_batchseq_strict(self):
        for v in (-1, 1.0, True):
            with self.subTest(v=v):
                b = make_batch()
                b["batchSeq"] = v
                self.assertStatus(self.srv.ingest(b, idem=False), 400)

    def test_t0utc_must_have_milliseconds_and_z(self):
        for v in ("2026-11-21T09:15:32Z", "2026-11-21T09:15:32.120+00:00", "2026-11-21",
                  "2026-13-21T09:15:32.120Z"):
            with self.subTest(v=v):
                b = make_batch()
                b["t0Utc"] = v
                self.assertStatus(self.srv.ingest(b), 400)

    def test_units_must_match(self):
        b = make_batch()
        b["units"]["accel"] = "m/s2"
        self.assertStatus(self.srv.ingest(b), 400)

    def test_unequal_arrays_and_missing_label_null_rejected(self):
        b = make_batch()
        b["gyroRaw"]["x"].append(0.5)
        self.assertStatus(self.srv.ingest(b), 400)
        b = make_batch()
        del b["labels"][0]["note"]
        self.assertStatus(self.srv.ingest(b), 400)

    def test_idempotency_key_mismatch_rejected(self):
        b = make_batch(seq=3)
        self.assertStatus(self.srv.ingest(b, extra={"x-idempotency-key": f"{b['sessionId']}:4"}), 400)

    def test_probe_is_400_with_probe_reason(self):
        raw = gzip.compress(b'{"probe":true}')
        p = self.assertStatus(self.srv.ingest(raw=raw, extra={"x-probe": "1"}), 400)
        self.assertIn("probe", p["error"])
        # ...and 401 when the key is wrong (the app reports "device key rejected")
        self.assertStatus(self.srv.ingest(raw=raw, key="wrong", extra={"x-probe": "1"}), 401)
        # The app's probe names its deviceId (the real ingest checks the key's binding; the mock has none).
        named = gzip.compress(b'{"probe":true,"deviceId":"8C3F1A2B-0000-4000-8000-000000000001"}')
        self.assertIn("probe", self.assertStatus(self.srv.ingest(raw=named, extra={"x-probe": "1"}), 400)["error"])

    def test_pre_d48_audio_keys_are_ignored(self):
        """D48 (no audio), as the ingest function: older builds still send audioLevel in batches
        and audioEnabled in session.json. Neither is required or checked, even when malformed."""
        for level in ({"t": [0.0], "avgDbfs": [-40.0], "peakDbfs": [-20.0]},
                      {"t": [0.0, 0.1], "avgDbfs": ["loud"]}, None):
            with self.subTest(level=level):
                b = make_batch()
                b["audioLevel"] = level
                self.assertStatus(self.srv.ingest(b), 201)
        for enabled in (True, False, "yes", 1, None):
            with self.subTest(enabled=enabled):
                m = make_meta()
                m["audioEnabled"] = enabled
                m["requestedRatesHz"]["audioLevel"] = 10
                self.assertStatus(self.srv.put_meta(m), 201)

    def test_empty_batch_is_201(self):
        self.assertStatus(self.srv.ingest(make_batch(n=0)), 201)

    def test_health_route_is_404(self):
        self.assertStatus(self.srv.request("GET", "/api/health", headers={"x-device-key": KEY}), 404)
        self.assertStatus(self.srv.request("GET", "/api/ingest"), 404)
        self.assertStatus(self.srv.request("POST", "/api/other", b"{}"), 404)

    def test_batch_over_200kb_decompressed_is_413(self):
        b = make_batch(n=2000)
        raw_json = json.dumps(b).encode()
        self.assertGreater(len(raw_json), 200 * 1024)
        p = self.assertStatus(self.srv.ingest(b), 413)
        self.assertIn("decompressed body larger than", p["error"])

    # -- PUT /api/ingest/sessions/<id> (spec §6.1) -------------------------------------------

    def test_meta_start_201_then_repeat_200(self):
        m = make_meta()
        p = self.assertStatus(self.srv.put_meta(m), 201)
        self.assertEqual(p["phase"], "start")
        p = self.assertStatus(self.srv.put_meta(m), 200)
        self.assertTrue(p.get("duplicate"))

    def test_meta_stop_with_batch_count_is_201(self):
        m = make_meta()
        self.assertStatus(self.srv.put_meta(m), 201)
        p = self.assertStatus(self.srv.put_meta(make_meta(m["sessionId"], batch_count=12)), 201)
        self.assertEqual(p["phase"], "stop")
        self.assertStatus(self.srv.put_meta(make_meta(m["sessionId"], batch_count=12)), 200)
        # recovered session: Stop copy without endedAtUtc is fine; batchCount 0 is valid
        self.assertStatus(self.srv.put_meta(make_meta(batch_count=0, recovered=True, ended=False)), 201)

    def test_meta_path_body_session_mismatch_is_400(self):
        m = make_meta()
        p = self.assertStatus(self.srv.put_meta(m, session_id=str(uuid.uuid4()).upper()), 400)
        self.assertIn("path sessionId", p["error"])

    def test_meta_stop_needs_end_or_recovered(self):
        p = self.assertStatus(self.srv.put_meta(make_meta(batch_count=3, ended=False)), 400)
        self.assertIn("endedAtUtc", p["error"])

    def test_meta_idempotency_key_must_match_phase(self):
        m = make_meta(batch_count=3)
        p = self.assertStatus(self.srv.put_meta(
            m, extra={"x-idempotency-key": f"{m['sessionId']}:meta-start"}), 400)
        self.assertIn("x-idempotency-key", p["error"])
        m = make_meta()
        self.assertStatus(self.srv.put_meta(m, extra={"x-idempotency-key": f"{m['sessionId']}:meta-stop"}), 400)
        self.assertStatus(self.srv.put_meta(m, extra={"x-idempotency-key": f"{m['sessionId']}:0"}), 400)
        self.assertStatus(self.srv.put_meta(m, idem=False), 201)  # header is optional

    def test_meta_schema_strict(self):
        cases = [("batchCount", -1), ("batchCount", 2.0), ("batchCount", True), ("recovered", None),
                 ("startUptimeSec", "1"), ("startedAtUtc", None), ("endedAtUtc", 5),
                 ("vehicle", None), ("mount", []), ("people", "x")]
        for k, v in cases:
            with self.subTest(k=k, v=v):
                m = make_meta(batch_count=1)
                m[k] = v
                self.assertStatus(self.srv.put_meta(m, idem=False), 400)
        m = make_meta()
        del m["endedAtUtc"]
        self.assertStatus(self.srv.put_meta(m), 400)
        self.assertStatus(self.srv.put_meta(raw=gzip.compress(b"[1]"), session_id="ABC"), 400)

    def test_meta_wrong_key_is_401_before_body(self):
        self.assertStatus(self.srv.put_meta(make_meta(), key="wrong"), 401)
        self.assertStatus(self.srv.put_meta(make_meta(), key=None), 401)
        self.assertStatus(self.srv.put_meta(raw=b"junk", session_id="ABC", key="wrong", encoding="br"), 401)

    def test_meta_already_inflated_is_accepted(self):
        m = make_meta()
        self.assertStatus(self.srv.put_meta(m, raw=json.dumps(m).encode(), encoding=None), 201)
        m = make_meta()
        self.assertStatus(self.srv.put_meta(m, raw=json.dumps(m).encode(), encoding="gzip"), 201)
        self.assertStatus(self.srv.put_meta(m, raw=b"\x00junk", encoding="gzip"), 400)
        self.assertStatus(self.srv.put_meta(m, extra={"Content-Type": "text/plain"}), 400)

    def test_meta_needs_device_id_and_capped_strings(self):
        m = make_meta()
        m["deviceId"] = ""
        self.assertStatus(self.srv.put_meta(m), 400)
        m = make_meta()
        m["vehicle"]["notes"] = "v" * 2001
        self.assertStatus(self.srv.put_meta(m), 400)
        m = make_meta()
        m["mount"]["location"] = "nul\x00"
        self.assertStatus(self.srv.put_meta(m), 400)

    def test_meta_nan_rejected(self):
        m = make_meta()
        raw = gzip.compress(json.dumps(m).replace('"startUptimeSec": 123456.789012',
                                                  '"startUptimeSec": Infinity').encode())
        p = self.assertStatus(self.srv.put_meta(m, raw=raw), 400)
        self.assertIn("invalid JSON", p["error"])

    def test_meta_over_200kb_decompressed_is_413(self):
        m = make_meta()
        m["conditions"]["notes"] = "x" * (200 * 1024)
        self.assertStatus(self.srv.put_meta(m), 413)

    def test_sessions_path_other_methods_are_404(self):
        # Like an Azure Functions route restricted to PUT: other methods get 404 (not 405).
        sid = str(uuid.uuid4()).upper()
        raw = gzip.compress(json.dumps(make_meta(sid)).encode())
        h = {"x-device-key": KEY, "Content-Type": "application/json", "Content-Encoding": "gzip"}
        path = f"/api/ingest/sessions/{sid}"
        self.assertStatus(self.srv.request("GET", path, headers=h), 404)
        self.assertStatus(self.srv.request("POST", path, raw, h), 404)
        self.assertStatus(self.srv.request("DELETE", path, headers=h), 404)
        self.assertStatus(self.srv.request("PUT", "/api/ingest", raw, h), 404)

    def test_sessions_unknown_subpaths_are_404(self):
        sid = str(uuid.uuid4()).upper()
        raw = gzip.compress(json.dumps(make_meta(sid)).encode())
        h = {"x-device-key": KEY, "Content-Type": "application/json", "Content-Encoding": "gzip"}
        for path in (f"/api/ingest/sessions/{sid}/extra", f"/api/ingest/sessions/{sid}/",
                     "/api/ingest/sessions/", "/api/ingest/sessions", f"/api/ingest/session/{sid}",
                     f"/api/ingest/sessions/{sid}%2F..", f"/api/ingest/sessions/{sid}.json"):
            with self.subTest(path=path):
                self.assertStatus(self.srv.request("PUT", path, raw, h), 404)
        # query strings are ignored, as on the batch route
        self.assertStatus(self.srv.request("PUT", f"/api/ingest/sessions/{sid}?x=1", raw, h), 201)

    def test_contract_fixture_from_swift_encoder(self):
        if not os.path.exists(FIXTURE):
            self.skipTest(f"{os.path.relpath(FIXTURE, HERE)} missing - it is written by the Swift "
                          f"unit tests (xcodebuild ... -only-testing:SensorRecorderTests test); "
                          f"cross-language contract not checked")
        with open(FIXTURE, "rb") as fh:
            raw = fh.read()
        doc = json.loads(gzip.decompress(raw).decode("utf-8"))
        headers = {"Content-Type": "application/json", "Content-Encoding": "gzip",
                   "x-idempotency-key": f"{doc['sessionId']}:{doc['batchSeq']}",
                   "x-device-key": KEY}
        status, payload = self.srv.request("POST", "/api/ingest", raw, headers)
        self.assertEqual(status, 201, f"app-encoded batch rejected by the mock backend: {payload}")

    def test_full_dataset_blocks_validated_when_present(self):
        b = make_batch(seq=0)
        b["magRaw"] = {"t": [0.0, 0.02], "x": [1.0, 2.0], "y": [0.0, 0.0], "z": [-40.0, -40.0]}
        b["absAltitude"] = {"t": [0.5], "altitudeM": [352.0], "accuracyM": [3.5], "precisionM": [0.4]}
        b["heading"] = [{"tUtcMs": 1763716532100, "magHeading": 91.0, "trueHeading": 95.0, "headingAcc": 10.0,
                         "x": 1.0, "y": 2.0, "z": 3.0}]
        b["activity"] = [{"t": 0.6, "stationary": False, "walking": False, "running": False, "automotive": True,
                          "cycling": False, "unknown": False, "confidence": 2, "startUtcMs": 1763716500000}]
        self.assertEqual(self.srv.ingest(b)[0], 201)
        bad = make_batch(seq=1)
        bad["magRaw"] = {"t": [0.0, 0.02], "x": [1.0], "y": [0.0, 0.0], "z": [0.0, 0.0]}
        self.assertEqual(self.srv.ingest(bad)[0], 400)
        bad2 = make_batch(seq=2)
        bad2["activity"] = [{"t": 0.6, "automotive": "yes", "confidence": 5, "startUtcMs": 1}]
        self.assertEqual(self.srv.ingest(bad2)[0], 400)

    def test_contract_session_metadata_fixture_from_swift(self):
        """§6.1 Stop copy built by the app's own code (RecordingSession.sessionMetadataBody)."""
        path = os.path.join(os.path.dirname(FIXTURE), "session_meta_stop_v1.json.gz")
        if not os.path.exists(path):
            self.skipTest("session_meta_stop_v1.json.gz missing - written by the Swift unit tests "
                          "(TEST_RUNNER_REGENERATE_FIXTURES=1); cross-language contract not checked")
        with open(path, "rb") as fh:
            raw = fh.read()
        doc = json.loads(gzip.decompress(raw).decode("utf-8"))
        self.assertIn("batchCount", doc)
        headers = {"Content-Type": "application/json", "Content-Encoding": "gzip",
                   "x-idempotency-key": f"{doc['sessionId']}:meta-stop", "x-device-key": KEY}
        status, payload = self.srv.request("PUT", f"/api/ingest/sessions/{doc['sessionId']}", raw, headers)
        self.assertEqual(status, 201, f"app-built session metadata rejected by the mock backend: {payload}")


class MockIngestDupStatusTests(unittest.TestCase):
    def test_dup_status_409_and_summary_on_sigterm(self):
        srv = MockServer("--dup-status", "409")
        try:
            b = make_batch(seq=0)
            self.assertEqual(srv.ingest(b, key=None)[0], 201)
            self.assertEqual(srv.ingest(b, key=None)[0], 409)
            self.assertEqual(srv.ingest(make_batch(seq=2, session_id=b["sessionId"]), key=None)[0], 201)
            self.assertEqual(srv.ingest(raw=b"\x1f\x8bbroken", key=None)[0], 400)
        finally:
            out = srv.stop()
        self.assertIn("== mock ingest summary ==", out)
        self.assertIn("unique batches: 2 in 1 session(s); duplicates answered 409: 1", out)
        self.assertIn("1 missing in between", out)
        self.assertIn("400 gzip: 1", out)

    def test_meta_repeat_answers_dup_status_409(self):
        srv = MockServer("--dup-status", "409")
        try:
            m = make_meta()
            self.assertEqual(srv.put_meta(m, key=None)[0], 201)
            self.assertEqual(srv.put_meta(m, key=None)[0], 409)
        finally:
            out = srv.stop()
        self.assertIn("repeats answered 409: 1", out)
        self.assertRegex(out, r"\d\d:\d\d:\d\d 201 PUT /api/ingest/sessions/\S+ sid=\S{8} "
                              r"phase=start batchCount=-")


class MockIngestSessionSummaryTests(unittest.TestCase):
    def test_summary_reports_missing_seqs_and_writes_metadata(self):
        tmp = tempfile.mkdtemp(prefix="mock-ingest-out-")
        try:
            srv = MockServer("--out", tmp)
            try:
                sid = str(uuid.uuid4()).upper()
                self.assertEqual(srv.put_meta(make_meta(sid), key=None)[0], 201)
                self.assertEqual(srv.ingest(make_batch(seq=0, session_id=sid), key=None)[0], 201)
                self.assertEqual(srv.ingest(make_batch(seq=2, session_id=sid), key=None)[0], 201)
                self.assertEqual(srv.put_meta(make_meta(sid, batch_count=3), key=None)[0], 201)
                # a late retry of the Start copy must not replace the stored Stop copy
                self.assertEqual(srv.put_meta(make_meta(sid), key=None)[0], 200)
                other = str(uuid.uuid4()).upper()  # metadata only, no batches
                self.assertEqual(srv.put_meta(make_meta(other), key=None)[0], 201)
            finally:
                out = srv.stop()
            self.assertIn(f"  {sid}: 2 batches, batchSeq 0..2, batchCount 3, missing 1 [1], "
                          f"meta start=yes stop=yes", out)
            self.assertIn(f"  {other}: 0 batches, batchCount unknown, meta start=yes stop=no", out)
            self.assertIn("session metadata: 2 start, 1 stop; repeats answered 200: 1", out)
            self.assertRegex(out, r"201 PUT /api/ingest/sessions/\S+ sid=\S{8} phase=stop batchCount=3")
            with open(os.path.join(tmp, "sessions", f"{sid}.json"), encoding="utf-8") as fh:
                stored = json.load(fh)
            self.assertEqual(stored["batchCount"], 3)
            self.assertTrue(os.path.exists(os.path.join(tmp, "sessions", f"{other}.json")))
            with open(os.path.join(tmp, f"{sid}.jsonl"), encoding="utf-8") as fh:
                self.assertEqual(len(fh.readlines()), 2)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
