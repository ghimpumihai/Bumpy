#!/usr/bin/env python3
"""mock_ingest_server.py: stdlib mock of the Azure ingest backend (spec §6) for local testing.

Usage:
    python3 tools/mock_ingest_server.py [--port 8080] [--key KEY] [--out DIR] [--fail-every N]

Then set the app's API base URL to http://<laptop-LAN-IP>:<port> (and the device key to KEY).
Note: iOS App Transport Security blocks plain http unless the app allows it (or use a tunnel).

Endpoints:
  GET  /api/health -> 200 {"ok": true}; 401 if --key is set and x-device-key differs.
  POST /api/ingest -> body must be gzip JSON (Content-Encoding: gzip), schemaVersion 1.
       201 accepted | 400 malformed/invalid (reason in JSON "error") | 401 bad x-device-key
       409 duplicate (sessionId, batchSeq) already accepted (in-memory dedupe)
       503 every Nth POST /api/ingest when --fail-every N is given (tests retry/backoff)
  x-idempotency-key, when present, must equal "<sessionId>:<batchSeq>".

One log line per request. With --out DIR, accepted batches are appended as JSON lines to
DIR/<sessionId>.jsonl. Binds 0.0.0.0 using ThreadingHTTPServer. Ctrl-C to stop.
"""

import argparse
import datetime as dt
import json
import math
import os
import re
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 20 * 1024 * 1024        # compressed
MAX_INFLATED = 100 * 1024 * 1024   # decompressed (zip-bomb guard)

REQUIRED_KEYS = ["schemaVersion", "sessionId", "deviceId", "batchSeq", "t0Utc", "t0Up", "units",
                 "deviceMotion", "accelRaw", "gyroRaw", "location", "altimeter", "audioLevel",
                 "labels", "device"]
# Columnar blocks (IngestBatch.swift): required array keys besides "t".
COLUMNAR = {
    "deviceMotion": ["ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
                     "q_w", "q_x", "q_y", "q_z"],
    "accelRaw": ["x", "y", "z"],
    "gyroRaw": ["x", "y", "z"],
    "altimeter": ["relAltM", "pressureKpa"],
    "audioLevel": ["avgDbfs", "peakDbfs"],
}
LOCATION_KEYS = ["tUtcMs", "lat", "lon", "alt", "hAcc", "speed", "speedAcc", "course"]


class Invalid(Exception):
    pass


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def validate(b):
    """Raises Invalid(reason) if the batch does not match the schemaVersion 1 contract."""
    if not isinstance(b, dict):
        raise Invalid("body is not a JSON object")
    missing = [k for k in REQUIRED_KEYS if k not in b]
    if missing:
        raise Invalid(f"missing top-level keys: {', '.join(missing)}")
    if b["schemaVersion"] != 1 or isinstance(b["schemaVersion"], bool):
        raise Invalid(f"schemaVersion must be 1, got {b['schemaVersion']!r}")
    for k in ("sessionId", "deviceId", "t0Utc"):
        if not isinstance(b[k], str) or not b[k]:
            raise Invalid(f"{k} must be a non-empty string")
    if not isinstance(b["batchSeq"], int) or isinstance(b["batchSeq"], bool) or b["batchSeq"] < 0:
        raise Invalid("batchSeq must be a non-negative integer")
    try:
        dt.datetime.fromisoformat(b["t0Utc"].replace("Z", "+00:00"))
    except ValueError:
        raise Invalid(f"t0Utc is not ISO-8601: {b['t0Utc']!r}")
    if not is_num(b["t0Up"]):
        raise Invalid("t0Up must be a finite number")
    if not isinstance(b["units"], dict):
        raise Invalid("units must be an object")

    for block, cols in COLUMNAR.items():
        blk = b[block]
        if not isinstance(blk, dict):
            raise Invalid(f"{block} must be an object")
        if not isinstance(blk.get("t"), list):
            raise Invalid(f"{block}.t must be an array")
        n = len(blk["t"])
        for c in ["t"] + cols:
            if c not in blk:
                raise Invalid(f"{block}.{c} missing")
        for c, arr in blk.items():
            if not isinstance(arr, list):
                raise Invalid(f"{block}.{c} must be an array")
            if len(arr) != n:
                raise Invalid(f"{block}.{c} has length {len(arr)} but {block}.t has {n}")
            if not all(is_num(v) for v in arr):
                raise Invalid(f"{block}.{c} contains non-numeric values")

    if not isinstance(b["location"], list):
        raise Invalid("location must be an array")
    for i, loc in enumerate(b["location"]):
        if not isinstance(loc, dict):
            raise Invalid(f"location[{i}] must be an object")
        for k in LOCATION_KEYS:
            if not is_num(loc.get(k)):
                raise Invalid(f"location[{i}].{k} missing or not a number")
        if not (-90 <= loc["lat"] <= 90 and -180 <= loc["lon"] <= 180):
            raise Invalid(f"location[{i}] lat/lon out of range")

    if not isinstance(b["labels"], list):
        raise Invalid("labels must be an array")
    for i, lab in enumerate(b["labels"]):
        if not isinstance(lab, dict):
            raise Invalid(f"labels[{i}] must be an object")
        for k in ("t", "type", "value", "note"):
            if k not in lab:
                raise Invalid(f"labels[{i}].{k} missing (use explicit null)")
        if not is_num(lab["t"]) or not isinstance(lab["type"], str):
            raise Invalid(f"labels[{i}]: t must be a number and type a string")
        for k in ("value", "note"):
            if lab[k] is not None and not isinstance(lab[k], str):
                raise Invalid(f"labels[{i}].{k} must be a string or null")

    d = b["device"]
    if not isinstance(d, dict):
        raise Invalid("device must be an object")
    if not is_num(d.get("battery")) or not isinstance(d.get("thermal"), str) \
            or not isinstance(d.get("lowPower"), bool):
        raise Invalid("device must have battery (number), thermal (string), lowPower (bool)")


def counts(b):
    def n(block):
        v = b.get(block)
        if isinstance(v, dict):
            return len(v.get("t") or [])
        return len(v) if isinstance(v, list) else 0
    return (f"dm={n('deviceMotion')} acc={n('accelRaw')} gyro={n('gyroRaw')} loc={n('location')} "
            f"alt={n('altimeter')} aud={n('audioLevel')} lab={n('labels')}")


def _reject_constant(name):
    raise ValueError(f"non-finite number {name} not allowed")


class State:
    def __init__(self, key, out, fail_every):
        self.key = key
        self.out = out
        self.fail_every = fail_every
        self.lock = threading.Lock()
        self.seen = set()
        self.ingest_count = 0


class Handler(BaseHTTPRequestHandler):
    server_version = "MockIngest/1.0"
    protocol_version = "HTTP/1.1"
    state = None  # set in main

    def log_message(self, fmt, *args):  # silence default access log; we log our own lines
        pass

    def _log(self, status, info=""):
        ts = dt.datetime.now().strftime("%H:%M:%S")
        print(f"{ts} {status} {self.command} {self.path} {info}".rstrip(), flush=True)

    def _send(self, status, obj, info=""):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self._log(status, info)

    def _key_ok(self):
        k = self.state.key
        return k is None or self.headers.get("x-device-key") == k

    def _drain_body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            self.close_connection = True
            return None, n
        return self.rfile.read(n), n

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path != "/api/health":
            return self._send(404, {"error": "not found"})
        if not self._key_ok():
            return self._send(401, {"error": "bad x-device-key"})
        self._send(200, {"ok": True})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        raw, n = self._drain_body()
        if path != "/api/ingest":
            return self._send(404, {"error": "not found"})
        st = self.state
        with st.lock:
            st.ingest_count += 1
            nth = st.ingest_count
        if st.fail_every and nth % st.fail_every == 0:
            return self._send(503, {"error": f"simulated outage (request #{nth})"},
                              f"simulated 503 (#{nth})")
        if not self._key_ok():
            return self._send(401, {"error": "bad x-device-key"})
        if raw is None:
            return self._send(413 if n > MAX_BODY else 400, {"error": "missing/invalid Content-Length"})

        def bad(reason, sid="-", seq="-"):
            return self._send(400, {"error": reason}, f"sid={sid} seq={seq} reason={reason}")

        if "gzip" not in (self.headers.get("Content-Encoding") or "").lower():
            return bad("Content-Encoding must be gzip")
        if not (self.headers.get("Content-Type") or "").lower().startswith("application/json"):
            return bad("Content-Type must be application/json")
        try:
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            body = d.decompress(raw, MAX_INFLATED)
            if d.unconsumed_tail:
                return bad("decompressed body too large")
            if not d.eof:
                raise zlib.error("truncated gzip stream")
        except zlib.error as e:
            return bad(f"gzip decode failed: {e}")
        try:
            b = json.loads(body.decode("utf-8"), parse_constant=_reject_constant)
        except (UnicodeDecodeError, ValueError) as e:
            return bad(f"invalid JSON: {e}")

        sid = b.get("sessionId") if isinstance(b, dict) else None
        seq = b.get("batchSeq") if isinstance(b, dict) else None
        sid_short = str(sid)[:8] if sid else "-"
        try:
            validate(b)
        except Invalid as e:
            return bad(str(e), sid_short, seq)
        idem = self.headers.get("x-idempotency-key")
        if idem is not None and idem != f"{sid}:{seq}":
            return bad(f"x-idempotency-key {idem!r} != '{sid}:{seq}'", sid_short, seq)

        info = f"sid={sid_short} seq={seq} {counts(b)}"
        with st.lock:
            if (sid, seq) in st.seen:
                dup = True
            else:
                dup = False
                st.seen.add((sid, seq))
                if st.out:
                    safe = re.sub(r"[^A-Za-z0-9._-]", "_", sid)[:128]
                    with open(os.path.join(st.out, f"{safe}.jsonl"), "a", encoding="utf-8") as fh:
                        fh.write(json.dumps(b, separators=(",", ":")) + "\n")
        if dup:
            return self._send(409, {"error": "duplicate", "sessionId": sid, "batchSeq": seq},
                              info + " duplicate")
        self._send(201, {"ok": True, "sessionId": sid, "batchSeq": seq}, info)


def main():
    ap = argparse.ArgumentParser(description="Mock /api/ingest + /api/health server (stdlib only).")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--key", default=None, help="require this x-device-key (default: accept any)")
    ap.add_argument("--out", default=None, help="append accepted batches to DIR/<sessionId>.jsonl")
    ap.add_argument("--fail-every", type=int, default=0, metavar="N",
                    help="return 503 for every Nth POST /api/ingest")
    a = ap.parse_args()
    if a.out:
        os.makedirs(a.out, exist_ok=True)
    Handler.state = State(a.key, a.out, a.fail_every if a.fail_every > 0 else 0)
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    srv.daemon_threads = True
    print(f"mock ingest server on http://{a.host}:{a.port}  key={'set' if a.key else 'any'} "
          f"out={a.out or '-'} fail_every={a.fail_every or '-'}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
