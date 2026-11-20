#!/usr/bin/env python3
"""test_tools.py: stdlib unittest suite for quick_check.py and mock_ingest_server.py.

Usage:
    python3 -I src/mobile-ios/tools/test_tools.py -v

Both tools are run as subprocesses (exactly as the team runs them), with the same interpreter.
  - quick_check: synthetic session folders (valid and deliberately broken) in a temp dir.
  - mock_ingest_server: started on a free port, exercised over HTTP, always terminated.
  - contract test: if tools/fixtures/ingest_batch_v1.json.gz exists (written by the Swift unit
    tests from the app's real IngestBatch encoder), it is POSTed unchanged and must get 201.
Python 3.9+, stdlib only.
"""

import gzip
import http.client
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
KEY = "test-device-key"

# ----------------------------------------------------------------------------------------------
# Synthetic session folders (headers must match SessionFiles.swift / quick_check.EXPECTED_HEADERS)
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


def make_session(folder, audio_enabled=True, write_audio=True, gyro_gap=None, location_header=None,
                 utc_offset_ms=0, legacy_meta=False, empty_altimeter=False):
    """Writes a ~30 s session that passes every quick_check rule unless a knob breaks it."""
    os.makedirs(folder)
    u0 = int(time.time() * 1000) - 120_000  # wall clock at T0_UP, 2 minutes ago

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

    record_audio = audio_enabled and write_audio
    clock = [f"{T0_UP:.6f},{utc(T0_UP)},start"]
    if record_audio:
        clock.append(f"{T0_UP + 0.2:.6f},{utc(T0_UP + 0.2)},audio_start")
    for k in range(1, int(DURATION // 10) + 1):
        t = T0_UP + 10 * k
        clock.append(f"{t:.6f},{utc(t)},periodic")
    write("clock", clock)

    dm = [f"{t:.6f},{utc(t) + utc_offset_ms},0.001,-0.002,0.003,0.0,0.0,-1.0,0.01,0.02,0.03,"
          f"1.0,0.0,0.0,0.0,0.0,0.0,0.0" for t in ticks(100)]
    write("device_motion", dm)
    write("accel_raw", [f"{t:.6f},{utc(t)},0.0,0.0,-1.0" for t in ticks(100)])
    gyro = ticks(100)
    if gyro_gap:
        a, b = gyro_gap
        gyro = [t for t in gyro if not (T0_UP + a < t < T0_UP + b)]
    write("gyro_raw", [f"{t:.6f},{utc(t)},0.01,0.02,0.03" for t in gyro])
    write("mag_raw", [f"{t:.6f},{utc(t)},10.0,20.0,-30.0" for t in ticks(50)])
    write("location", [f"{t:.6f},{utc(t)},{46.77121 + i * 1e-5:.8f},23.62363000,352.1,390.2,4.7,3.0,"
                       f"8.4,0.5,92.0,10.0,0" for i, t in enumerate(ticks(1))],
          header=location_header)
    write("heading", [f"{t:.6f},{utc(t)},91.0,95.0,5.0,10.0,20.0,-30.0" for t in ticks(1)])
    write("altimeter", [] if empty_altimeter else
          [f"{t:.6f},{utc(t)},0.1,96.5" for t in ticks(1)])
    write("abs_altitude", [f"{t:.6f},{utc(t)},352.0,5.0,1.0" for t in ticks(1)])
    write("activity", [f"{T0_UP + 1:.6f},{utc(T0_UP + 1)},0,0,0,1,0,0,2,{utc(T0_UP)}"])
    write("audio_level", [f"{t:.6f},{utc(t)},-40.5,-20.1" for t in ticks(10)])
    write("device", [f"{t:.6f},{utc(t)},0.82,unplugged,nominal,0,50000000000,satisfied,wifi"
                     for t in ticks(0.2)])
    labels = [
        f"{T0_UP + 5:.6f},{utc(T0_UP + 5)},pothole,,",
        f"{T0_UP + 10:.6f},{utc(T0_UP + 10)},sickness,4,",
        # multi-line quoted note with a comma and an escaped quote: must count as ONE label
        f'{T0_UP + 15:.6f},{utc(T0_UP + 15)},note,,"first line, with comma\nsecond ""line"""',
    ]
    write("labels", labels)
    if record_audio:
        write("audio_segments", [f"{T0_UP + 0.2:.6f},{utc(T0_UP + 0.2)},start,audio_000.m4a",
                                 f"{T0_UP + DURATION:.6f},{utc(T0_UP + DURATION)},stop,audio_000.m4a"])
        with open(os.path.join(folder, "audio_000.m4a"), "wb") as fh:
            fh.write(b"\x00\x00\x00\x18ftypM4A " + b"\x00" * 4096)
    else:
        write("audio_segments", [])

    meta = {
        "sessionId": str(uuid.uuid4()).upper(),
        "appVersion": "1.0.0 (test)",
        "device": {"model": "iPhone15,2", "name": "iPhone 14 Pro", "iosVersion": "18.1"},
        "timezone": "Europe/Bucharest",
        "startedAtUtc": iso(u0),
        "startUptimeSec": T0_UP,
        "endedAtUtc": iso(utc(T0_UP + DURATION)),
        "vehicle": {"type": "car", "makeModel": "Test Car", "line": None, "notes": ""},
        "mount": {"location": "taped flat on center console", "phoneOrientation": "screen up",
                  "rigid": True, "handheld": False, "seatOverAxle": False, "photoFile": None},
        "people": {"operatorSeat": "front passenger", "raterSeat": "rear left",
                   "raterPosture": "seated", "passengerCount": 2, "raterName": ""},
        "conditions": {"weather": "dry", "notes": ""},
        "audioEnabled": audio_enabled,
        "requestedRatesHz": {"deviceMotion": 100, "accel": 100, "gyro": 100, "mag": 50,
                             "audioLevel": 10},
        "recovered": False,
        "syntheticSensors": False,
        "folderName": os.path.basename(folder),
        "deviceId": str(uuid.uuid4()).upper(),
        "preflight": {"completedAtUtc": iso(u0 - 5000), "overridden": False, "checks": []},
        "stats": None,
    }
    if legacy_meta:
        del meta["audioEnabled"]
        del meta["vehicle"]["line"]
        del meta["mount"]["handheld"]
        del meta["mount"]["seatOverAxle"]
        del meta["people"]["raterPosture"]
    with open(os.path.join(folder, "session.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
    return folder


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
        self.assertIn("audioEnabled", out)
        self.assertIn("people.raterPosture", out)

    def test_gyro_gap_half_second_fails(self):
        self.assertFail(self.session("gap", gyro_gap=(10.0, 10.5)), "gyro_raw: ", "max gap 0.5")

    def test_wrong_location_header_fails_without_crash(self):
        bad = HEADERS["location"].replace("is_simulated", "is_sim")
        out = self.assertFail(self.session("hdr", location_header=bad),
                              "location.csv: header mismatch")
        self.assertIn("is_simulated", out)
        # later sections still ran
        self.assertIn("== labels.csv ==", out)
        self.assertIn("== audio ==", out)

    def test_utc_offset_500ms_fails(self):
        self.assertFail(self.session("utc", utc_offset_ms=500), "device_motion: t_utc_ms")

    def test_utc_offset_50ms_warns(self):
        code, out = run_quick_check(self.session("utc50", utc_offset_ms=50))
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"\[WARN\] device_motion: t_utc_ms")

    def test_missing_audio_with_audio_enabled_fails(self):
        self.assertFail(self.session("noaudio", audio_enabled=True, write_audio=False),
                        "MISSING audio")

    def test_audio_disabled_without_audio_is_not_fail(self):
        code, out = run_quick_check(self.session("privacy", audio_enabled=False))
        self.assertRan(out)
        self.assertEqual(code, 0, out)
        self.assertIn("audio recording OFF (privacy)", out)
        self.assertNotIn("MISSING audio", out)

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
        self.assertIn("[INFO] session.json: no audioEnabled (older app version)", out)

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
        h = {"Content-Type": "application/json", "Content-Encoding": encoding}
        if key is not None:
            h["x-device-key"] = key
        if idem and isinstance(batch, dict) and "sessionId" in batch:
            h["x-idempotency-key"] = f"{batch['sessionId']}:{batch.get('batchSeq')}"
        h.update(extra or {})
        return self.request("POST", "/api/ingest", raw, h)


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
        "audioLevel": {"t": t, "avgDbfs": v, "peakDbfs": v},
        "labels": [{"t": 0.01, "type": "pothole", "value": None, "note": None}] if n else [],
        "device": {"battery": 0.82, "thermal": "nominal", "lowPower": False},
    }


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

    def test_content_encoding_must_be_exactly_gzip(self):
        for enc in ("x-gzip", "gzip, br", "GZIP ", "identity"):
            with self.subTest(enc=enc):
                self.assertStatus(self.srv.ingest(make_batch(), encoding=enc), 400)

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

    def test_empty_batch_is_201(self):
        self.assertStatus(self.srv.ingest(make_batch(n=0)), 201)

    def test_health_route_is_404(self):
        self.assertStatus(self.srv.request("GET", "/api/health", headers={"x-device-key": KEY}), 404)
        self.assertStatus(self.srv.request("GET", "/api/ingest"), 404)
        self.assertStatus(self.srv.request("POST", "/api/other", b"{}"), 404)

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


class MockIngestDupStatusTests(unittest.TestCase):
    def test_dup_status_409_and_summary_on_sigterm(self):
        srv = MockServer("--dup-status", "409")
        try:
            b = make_batch(seq=0)
            self.assertEqual(srv.ingest(b, key=None)[0], 201)
            self.assertEqual(srv.ingest(b, key=None)[0], 409)
            self.assertEqual(srv.ingest(make_batch(seq=2, session_id=b["sessionId"]), key=None)[0], 201)
            self.assertEqual(srv.ingest(b, key=None, encoding="x-gzip")[0], 400)
        finally:
            out = srv.stop()
        self.assertIn("== mock ingest summary ==", out)
        self.assertIn("unique batches: 2 in 1 session(s); duplicates answered 409: 1", out)
        self.assertIn("1 missing in between", out)
        self.assertIn("400 content-encoding: 1", out)


if __name__ == "__main__":
    unittest.main()
