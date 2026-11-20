#!/usr/bin/env python3
"""mock_ingest_server.py: stdlib stand-in for the AWS ingest backend (API Gateway + ingest Lambda,
decisions/02-infrastructure-plan.md §6/§7; app contract spec §6) for local testing.

Usage:
    python3 -I tools/mock_ingest_server.py [--port 8080] [--host 127.0.0.1] [--key KEY] [--out DIR]
                                           [--fail-every N] [--dup-status {200,409}]

Default: loopback only (Simulator). For a real phone on the same Wi-Fi:
    --host 0.0.0.0 --key <throwaway-key>   (a key is required on the network; never your real one:
                                            plain http on Wi-Fi is sniffable)
then set the app's API base URL to http://<laptop-LAN-IP>:<port> and the device key to that key.
--port 0 picks a free port; the first output line names the bound URL.

Endpoint (the only route; anything else is 404 like API Gateway, including GET /api/health):
  POST /api/ingest, checked in the same order as the Lambda:
    1. x-device-key (401 if --key is set and the header differs)
    2. Content-Encoding exactly "gzip" (400 otherwise, e.g. "x-gzip" or "gzip, br"),
       Content-Type application/json (400)
    3. gunzip with a size cap (413 compressed > 20 MB; 400 inflated > 100 MB, truncated stream,
       trailing data or more than one gzip member)
    4. JSON parse (400; NaN / Infinity / out-of-range numbers rejected)
    5. schema (400, reason in JSON "error"): schemaVersion int 1, batchSeq int >= 0,
       t0Utc "YYYY-MM-DDTHH:MM:SS.mmmZ", exact units, columnar arrays of equal length,
       location[].tUtcMs int, labels with explicit nulls, device object. A batch with 0 samples
       is valid. The app's connectivity probe body {"probe":true} (header x-probe: 1) gets 400
       with a reason naming the probe, i.e. "reachable, key accepted".
    6. x-idempotency-key, when present, must equal "<sessionId>:<batchSeq>" (400)
  201 new batch | --dup-status (default 200, as AWS: the backend dedupes later in the database)
  for a repeated (sessionId, batchSeq) | 503 every Nth POST when --fail-every N (tests backoff).

One log line per request. With --out DIR, accepted (unique) batches are appended as JSON lines to
DIR/<sessionId>.jsonl. Binds with ThreadingHTTPServer. Ctrl-C / SIGTERM prints a summary (unique
batches per session, rejects by reason) and exits 0.
"""

import argparse
import datetime as dt
import json
import math
import os
import re
import signal
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 20 * 1024 * 1024        # compressed
MAX_INFLATED = 100 * 1024 * 1024   # decompressed (zip-bomb guard)

REQUIRED_KEYS = ["schemaVersion", "sessionId", "deviceId", "batchSeq", "t0Utc", "t0Up", "units",
                 "deviceMotion", "accelRaw", "gyroRaw", "location", "altimeter", "audioLevel",
                 "labels", "device"]
EXPECTED_UNITS = {"accel": "g", "gyro": "rad/s", "speed": "m/s", "pressure": "kPa"}
# Columnar blocks (IngestBatch.swift): required array keys besides "t".
COLUMNAR = {
    "deviceMotion": ["ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
                     "q_w", "q_x", "q_y", "q_z"],
    "accelRaw": ["x", "y", "z"],
    "gyroRaw": ["x", "y", "z"],
    "altimeter": ["relAltM", "pressureKpa"],
    "audioLevel": ["avgDbfs", "peakDbfs"],
}
LOCATION_KEYS = ["lat", "lon", "alt", "hAcc", "speed", "speedAcc", "course"]
# ISO8601.string in the app: ISO8601DateFormatter [.withInternetDateTime, .withFractionalSeconds]
T0_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")


class Invalid(Exception):
    pass


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_int(v):
    return type(v) is int  # excludes bool and float (1.0)


def validate(b):
    """Raises Invalid(reason) if the batch does not match the schemaVersion 1 contract."""
    if not isinstance(b, dict):
        raise Invalid("body is not a JSON object")
    if b.get("probe") is True:
        raise Invalid("probe request (connectivity test): not an ingest batch, nothing stored - "
                      "endpoint reachable and device key accepted")
    missing = [k for k in REQUIRED_KEYS if k not in b]
    if missing:
        raise Invalid(f"missing top-level keys: {', '.join(missing)}")
    if not is_int(b["schemaVersion"]) or b["schemaVersion"] != 1:
        raise Invalid(f"schemaVersion must be the integer 1, got {b['schemaVersion']!r}")
    for k in ("sessionId", "deviceId", "t0Utc"):
        if not isinstance(b[k], str) or not b[k]:
            raise Invalid(f"{k} must be a non-empty string")
    if not is_int(b["batchSeq"]) or b["batchSeq"] < 0:
        raise Invalid(f"batchSeq must be a non-negative integer, got {b['batchSeq']!r}")
    if not T0_UTC_RE.match(b["t0Utc"]):
        raise Invalid(f"t0Utc must be ISO-8601 UTC with milliseconds "
                      f"(e.g. 2026-11-21T09:15:32.120Z), got {b['t0Utc']!r}")
    try:
        dt.datetime.strptime(b["t0Utc"], "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        raise Invalid(f"t0Utc is not a valid date/time: {b['t0Utc']!r}")
    if not is_num(b["t0Up"]):
        raise Invalid("t0Up must be a finite number")
    if b["units"] != EXPECTED_UNITS:
        raise Invalid(f"units must be {json.dumps(EXPECTED_UNITS)}, got {json.dumps(b['units'])}")
    # Additive fields (app >= review round 3): optional, but typed when present.
    for k in ("eventType", "source"):
        if k in b and (not isinstance(b[k], str) or not b[k]):
            raise Invalid(f"{k} must be a non-empty string when present")
    if "t0UtcMs" in b and not is_int(b["t0UtcMs"]):
        raise Invalid("t0UtcMs must be an integer (Unix ms) when present")
    if "fieldUnits" in b and (not isinstance(b["fieldUnits"], dict)
                              or not all(isinstance(k, str) and isinstance(v, str) for k, v in b["fieldUnits"].items())):
        raise Invalid("fieldUnits must be an object of string -> string when present")

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
        if "isSimulated" in loc and loc["isSimulated"] is not None and not isinstance(loc["isSimulated"], bool):
            raise Invalid(f"location[{i}].isSimulated must be true/false/null when present")
        if not is_int(loc.get("tUtcMs")):
            raise Invalid(f"location[{i}].tUtcMs missing or not an integer (Unix ms), "
                          f"got {loc.get('tUtcMs')!r}")
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


def _parse_float(s):
    v = float(s)
    if not math.isfinite(v):
        raise ValueError(f"number {s} out of range")
    return v


def gunzip_one_member(raw, limit):
    """Strict gzip decode: exactly one member, no trailing bytes, at most `limit` bytes out.
    Raises ValueError(reason)."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = d.decompress(raw, limit + 1)
    except zlib.error as e:
        raise ValueError(f"gzip decode failed: {e}")
    if len(out) > limit:
        raise ValueError(f"decompressed body larger than {limit} bytes")
    if not d.eof:
        raise ValueError("gzip decode failed: truncated gzip stream")
    if d.unused_data:
        if d.unused_data[:2] == b"\x1f\x8b":
            raise ValueError("multiple gzip members are not accepted")
        raise ValueError(f"{len(d.unused_data)} bytes of trailing data after the gzip stream")
    return out


class State:
    def __init__(self, key, out, fail_every, dup_status):
        self.key = key
        self.out = out
        self.fail_every = fail_every
        self.dup_status = dup_status
        self.lock = threading.Lock()
        self.sessions = {}      # sessionId -> set(batchSeq) accepted
        self.duplicates = 0
        self.rejects = {}       # "status category" -> [count, first reason]
        self.ingest_count = 0

    def reject(self, status, category, reason):
        with self.lock:
            k = f"{status} {category}"
            entry = self.rejects.setdefault(k, [0, reason])
            entry[0] += 1

    def summary(self):
        with self.lock:
            lines = ["", "== mock ingest summary =="]
            total = sum(len(s) for s in self.sessions.values())
            lines.append(f"unique batches: {total} in {len(self.sessions)} session(s); "
                         f"duplicates answered {self.dup_status}: {self.duplicates}")
            for sid, seqs in sorted(self.sessions.items()):
                lo, hi = min(seqs), max(seqs)
                holes = (hi - lo + 1) - len(seqs)
                lines.append(f"  {sid}: {len(seqs)} batches, batchSeq {lo}..{hi}"
                             + (f", {holes} missing in between" if holes else ""))
            n_rej = sum(c for c, _ in self.rejects.values())
            lines.append(f"rejects: {n_rej}")
            for k, (c, first) in sorted(self.rejects.items()):
                lines.append(f"  {k}: {c}  (e.g. {first})")
            return "\n".join(lines)


class Handler(BaseHTTPRequestHandler):
    server_version = "MockIngest/1.0"
    protocol_version = "HTTP/1.1"
    timeout = 15  # seconds per socket read: a slow/stalled client can't hold a thread forever
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

    def _reject(self, status, category, reason, info=""):
        self.state.reject(status, category, reason)
        return self._send(status, {"error": reason}, (info + " " if info else "") + f"reason={reason}")

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

    def _not_found(self):
        return self._send(404, {"message": "Not Found"})  # API Gateway's body for unknown routes

    def do_GET(self):
        self._not_found()

    def do_PUT(self):
        self._drain_body()
        self._not_found()

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        raw, n = self._drain_body()
        if path != "/api/ingest":
            return self._not_found()
        st = self.state
        with st.lock:
            st.ingest_count += 1
            nth = st.ingest_count
        if st.fail_every and nth % st.fail_every == 0:
            return self._reject(503, "simulated outage", f"simulated outage (request #{nth})")
        # 1. device key first (the Lambda authenticates before touching the body)
        if not self._key_ok():
            return self._reject(401, "bad key", "bad x-device-key")
        if raw is None:
            if n > MAX_BODY:
                return self._reject(413, "too large", f"body larger than {MAX_BODY} bytes")
            return self._reject(400, "content-length", "missing/invalid Content-Length")
        probe = self.headers.get("x-probe") == "1"

        # 2. headers
        enc = self.headers.get("Content-Encoding")
        if enc != "gzip":
            return self._reject(400, "content-encoding",
                                f"Content-Encoding must be exactly 'gzip', got {enc!r}")
        if not (self.headers.get("Content-Type") or "").lower().startswith("application/json"):
            return self._reject(400, "content-type", "Content-Type must be application/json")
        # 3. gunzip
        try:
            body = gunzip_one_member(raw, MAX_INFLATED)
        except ValueError as e:
            return self._reject(400, "gzip", str(e))
        # 4. JSON
        try:
            b = json.loads(body.decode("utf-8"), parse_constant=_reject_constant,
                           parse_float=_parse_float)
        except (UnicodeDecodeError, ValueError) as e:
            return self._reject(400, "json", f"invalid JSON: {e}")

        sid = b.get("sessionId") if isinstance(b, dict) else None
        seq = b.get("batchSeq") if isinstance(b, dict) else None
        ids = f"sid={str(sid)[:8] if sid else '-'} seq={seq if seq is not None else '-'}"
        # 5. schema
        try:
            validate(b)
        except Invalid as e:
            reason = str(e)
            category = "probe" if reason.startswith("probe request") else "schema"
            if probe and category != "probe":
                reason = f"probe request (x-probe: 1) with a non-probe body: {reason}"
            return self._reject(400, category, reason, ids)
        # 6. idempotency header
        idem = self.headers.get("x-idempotency-key")
        if idem is not None and idem != f"{sid}:{seq}":
            return self._reject(400, "idempotency-key",
                                f"x-idempotency-key {idem!r} != '{sid}:{seq}'", ids)

        info = f"{ids} {counts(b)}"
        with st.lock:
            seqs = st.sessions.setdefault(sid, set())
            dup = seq in seqs
            if dup:
                st.duplicates += 1
            else:
                seqs.add(seq)
                if st.out:
                    safe = re.sub(r"[^A-Za-z0-9._-]", "_", sid)[:128]
                    with open(os.path.join(st.out, f"{safe}.jsonl"), "a", encoding="utf-8") as fh:
                        fh.write(json.dumps(b, separators=(",", ":")) + "\n")
        if dup:
            return self._send(st.dup_status, {"ok": True, "duplicate": True, "sessionId": sid,
                                              "batchSeq": seq}, info + " duplicate")
        self._send(201, {"ok": True, "sessionId": sid, "batchSeq": seq}, info)


def _sigterm(signum, frame):
    raise KeyboardInterrupt


def main():
    ap = argparse.ArgumentParser(description="Mock AWS POST /api/ingest server (stdlib only).")
    ap.add_argument("--port", type=int, default=8080, help="0 = pick a free port")
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address (default loopback). Use 0.0.0.0 to accept the phone over Wi-Fi; "
                         "that requires --key (or --allow-any-key).")
    ap.add_argument("--allow-any-key", action="store_true",
                    help="accept any device key even when listening on the network (not recommended)")
    ap.add_argument("--key", default=None, help="require this x-device-key (default: accept any)")
    ap.add_argument("--out", default=None, help="append accepted batches to DIR/<sessionId>.jsonl")
    ap.add_argument("--fail-every", type=int, default=0, metavar="N",
                    help="return 503 for every Nth POST /api/ingest")
    ap.add_argument("--dup-status", type=int, choices=(200, 409), default=200,
                    help="status for a repeated (sessionId, batchSeq); AWS answers 200 (default)")
    a = ap.parse_args()
    if a.host not in ("127.0.0.1", "localhost", "::1") and not a.key and not a.allow_any_key:
        ap.error("listening on the network without --key lets anyone on the Wi-Fi inject batches; "
                 "pass --key <throwaway key> (or --allow-any-key)")
    if a.out:
        os.makedirs(a.out, exist_ok=True)
    state = State(a.key, a.out, a.fail_every if a.fail_every > 0 else 0, a.dup_status)
    Handler.state = state
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    srv.daemon_threads = True
    signal.signal(signal.SIGTERM, _sigterm)
    port = srv.server_address[1]
    print(f"mock ingest server on http://{a.host}:{port}  key={'set' if a.key else 'any'} "
          f"out={a.out or '-'} fail_every={a.fail_every or '-'} dup_status={a.dup_status}",
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
        print(state.summary(), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
