#!/usr/bin/env python3
"""mock_ingest_server.py: stdlib stand-in for the Azure ingest function (
decisions/02-infrastructure-plan.md §5; app contract spec §6, §6.1) for local testing.

Usage:
    python3 -I tools/mock_ingest_server.py [--port 8080] [--host 127.0.0.1] [--key KEY] [--out DIR]
                                           [--fail-every N] [--dup-status {200,409}]

Default: loopback only (Simulator). For a real phone on the same Wi-Fi:
    --host 0.0.0.0 --key <throwaway-key>   (a key is required on the network; never your real one:
                                            plain http on Wi-Fi is sniffable)
then set the app's API base URL to http://<laptop-LAN-IP>:<port> and the device key to that key.
--port 0 picks a free port; the first output line names the bound URL.

Routes (anything else is 404, including GET /api/health; a known path with another method is
also 404, as an Azure Functions route restricted to one method answers):
  POST /api/ingest                        one 2-second batch (spec §6)
  PUT  /api/ingest/sessions/<sessionId>   session.json at Start and at Stop (spec §6.1);
                                          <sessionId> = [A-Za-z0-9_-]{1,128}, no further segments

Both are checked in the same order as the ingest function:
    0. --fail-every N: every Nth request on either route gets 503 (tests the app's backoff)
    1. x-device-key (401 if --key is set and the header differs)
    2. Content-Type application/json (400)
    3. gunzip when the body starts with the gzip magic bytes 1f 8b, whatever Content-Encoding says
       (the app always sends "gzip"; the Functions host may inflate the body itself and drop the
       header, 02 §5); any other body is taken as JSON the host already inflated. Size caps: 413
       compressed > 20 MB or decompressed > 200 KB (the function's body limit, 02 §5); 400
       truncated stream, trailing data or more than one gzip member
    4. JSON parse (400; NaN / Infinity / out-of-range numbers rejected)
    5. schema and string limits (400, reason in JSON "error")
       POST: schemaVersion int 1, batchSeq int >= 0, t0Utc "YYYY-MM-DDTHH:MM:SS.mmmZ", exact
       units, columnar arrays of equal length, location[].tUtcMs int, labels with explicit nulls,
       device object; magRaw, absAltitude, heading, activity typed when present. A batch with 0
       samples is valid. The app's connectivity probe body {"probe":true} (header x-probe: 1)
       gets 400 with a reason naming the probe, i.e. "reachable, key accepted".
       PUT: a JSON object; sessionId string equal to the path id; deviceId non-empty string;
       startedAtUtc string; startUptimeSec number; endedAtUtc string or null; recovered bool;
       vehicle, mount, people objects; audioEnabled bool when present; batchCount int >= 0 when
       present. batchCount present = the Stop copy, which also needs endedAtUtc non-null or
       recovered true.
       Both: deviceId at most 128 characters, labels[].type at most 64, every other string and
       object key at most 2000; no string may contain NUL or an unpaired surrogate (PostgreSQL
       text/jsonb can't store them).
       (The function then answers 403 when the body's deviceId isn't the one the device key is
       stored under; the mock has a single key and skips that check.)
    6. x-idempotency-key, when present: POST "<sessionId>:<batchSeq>"; PUT "<sessionId>:meta-start"
       (no batchCount) or "<sessionId>:meta-stop" (with batchCount) (400 otherwise)
  201 first time a (sessionId, batchSeq) or (sessionId, start|stop) is seen | --dup-status
  (default 200, as the backend: it dedupes later in the database) for a repeat.

One log line per request. With --out DIR, accepted (unique) batches are appended as JSON lines to
DIR/<sessionId>.jsonl and the latest metadata is written to DIR/sessions/<sessionId>.json (a late
Start copy never overwrites a Stop copy). Binds with ThreadingHTTPServer. Ctrl-C / SIGTERM prints
a summary (per session: unique batches, batchCount from the Stop copy, missing batchSeqs, whether
the Start/Stop metadata arrived; rejects by reason) and exits 0.
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

MAX_BODY = 20 * 1024 * 1024        # compressed (413)
MAX_INFLATED = 200 * 1024          # decompressed: the ingest function rejects bodies over 200 KB (413)

INGEST_PATH = "/api/ingest"
SESSIONS_PREFIX = "/api/ingest/sessions/"
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

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
# Additive full-dataset blocks (02 D32): optional, validated when present.
OPTIONAL_COLUMNAR = {"magRaw": ["x", "y", "z"], "absAltitude": ["altitudeM", "accuracyM", "precisionM"]}
HEADING_NUM = ["magHeading", "trueHeading", "headingAcc", "x", "y", "z"]
ACTIVITY_BOOL = ["stationary", "walking", "running", "automotive", "cycling", "unknown"]
# ISO8601.string in the app: ISO8601DateFormatter [.withInternetDateTime, .withFractionalSeconds]
T0_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
# String limits, as the ingest function (services/ingest/ingest_core/contract.py).
MAX_ID_LEN = 128
MAX_LABEL_TYPE_LEN = 64
MAX_TEXT_LEN = 2000
_BAD_CHARS = re.compile(r"[\x00\ud800-\udfff]")


class Invalid(Exception):
    pass


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_int(v):
    return type(v) is int  # excludes bool and float (1.0)


def _short(path):
    return path if len(path) <= 80 else path[:77] + "..."


def check_strings(doc, limit=MAX_TEXT_LEN):
    """Every string and object key in `doc`: at most `limit` characters, no NUL, no lone
    surrogate. Iterative, so nesting depth doesn't matter. Raises Invalid(reason)."""
    stack = [("", doc)]
    while stack:
        path, v = stack.pop()
        if isinstance(v, str):
            if len(v) > limit:
                raise Invalid(f"{_short(path or 'body')}: string longer than {limit} characters")
            if _BAD_CHARS.search(v):
                raise Invalid(f"{_short(path or 'body')}: string contains NUL or an unpaired surrogate")
        elif isinstance(v, dict):
            for k, x in v.items():
                if len(k) > limit or _BAD_CHARS.search(k):
                    raise Invalid(f"{_short(path or 'body')}: object key longer than {limit} characters "
                                  "or containing NUL or an unpaired surrogate")
                if isinstance(x, (str, dict, list)):
                    stack.append((f"{path}.{k}" if path else k, x))
        elif isinstance(v, list):
            for i, x in enumerate(v):
                if isinstance(x, (str, dict, list)):
                    stack.append((f"{path}[{i}]", x))


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
    if len(b["deviceId"]) > MAX_ID_LEN:
        raise Invalid(f"deviceId must be at most {MAX_ID_LEN} characters")
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

    for block, cols in OPTIONAL_COLUMNAR.items():
        if block not in b:
            continue
        blk = b[block]
        if not isinstance(blk, dict) or not isinstance(blk.get("t"), list):
            raise Invalid(f"{block} must be an object with a t array")
        n = len(blk["t"])
        for c in ["t"] + cols:
            if c not in blk:
                raise Invalid(f"{block}.{c} missing")
        for c, arr in blk.items():
            if not isinstance(arr, list) or len(arr) != n or not all(is_num(v) for v in arr):
                raise Invalid(f"{block}.{c} must be a numeric array of length {n}")
    if "heading" in b:
        if not isinstance(b["heading"], list):
            raise Invalid("heading must be an array")
        for i, h in enumerate(b["heading"]):
            if not isinstance(h, dict) or not is_int(h.get("tUtcMs")) or not all(is_num(h.get(k)) for k in HEADING_NUM):
                raise Invalid(f"heading[{i}] needs int tUtcMs and numeric {', '.join(HEADING_NUM)}")
    if "activity" in b:
        if not isinstance(b["activity"], list):
            raise Invalid("activity must be an array")
        for i, a in enumerate(b["activity"]):
            if (not isinstance(a, dict) or not is_num(a.get("t")) or not is_int(a.get("startUtcMs"))
                    or not all(isinstance(a.get(k), bool) for k in ACTIVITY_BOOL)
                    or not is_int(a.get("confidence")) or a["confidence"] not in (0, 1, 2)):
                raise Invalid(f"activity[{i}] needs numeric t, int startUtcMs, booleans {', '.join(ACTIVITY_BOOL)}, confidence 0|1|2")

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
        if len(lab["type"]) > MAX_LABEL_TYPE_LEN:
            raise Invalid(f"labels[{i}].type must be at most {MAX_LABEL_TYPE_LEN} characters")
        for k in ("value", "note"):
            if lab[k] is not None and not isinstance(lab[k], str):
                raise Invalid(f"labels[{i}].{k} must be a string or null")

    d = b["device"]
    if not isinstance(d, dict):
        raise Invalid("device must be an object")
    if not is_num(d.get("battery")) or not isinstance(d.get("thermal"), str) \
            or not isinstance(d.get("lowPower"), bool):
        raise Invalid("device must have battery (number), thermal (string), lowPower (bool)")
    check_strings(b)


def validate_session_meta(m, path_id):
    """Validates a session.json body (spec §3.8/§6.1) for PUT /api/ingest/sessions/<path_id>.
    Returns the phase: "stop" when batchCount is present, else "start". Raises Invalid(reason)."""
    if not isinstance(m, dict):
        raise Invalid("body is not a JSON object")
    if not isinstance(m.get("sessionId"), str) or not m["sessionId"]:
        raise Invalid("sessionId must be a non-empty string")
    if m["sessionId"] != path_id:
        raise Invalid(f"body sessionId {m['sessionId']!r} != path sessionId {path_id!r}")
    # The ingest function binds each device key to a deviceId, so it must be there.
    if not isinstance(m.get("deviceId"), str) or not m["deviceId"]:
        raise Invalid("deviceId must be a non-empty string")
    if len(m["deviceId"]) > MAX_ID_LEN:
        raise Invalid(f"deviceId must be at most {MAX_ID_LEN} characters")
    if not isinstance(m.get("startedAtUtc"), str) or not m["startedAtUtc"]:
        raise Invalid("startedAtUtc must be a non-empty string")
    if not is_num(m.get("startUptimeSec")):
        raise Invalid("startUptimeSec must be a finite number")
    if "endedAtUtc" not in m:
        raise Invalid("endedAtUtc missing (use explicit null while recording)")
    if m["endedAtUtc"] is not None and (not isinstance(m["endedAtUtc"], str) or not m["endedAtUtc"]):
        raise Invalid("endedAtUtc must be a non-empty string or null")
    if not isinstance(m.get("recovered"), bool):
        raise Invalid("recovered must be true/false")
    for k in ("vehicle", "mount", "people"):
        if not isinstance(m.get(k), dict):
            raise Invalid(f"{k} must be an object")
    if "audioEnabled" in m and not isinstance(m["audioEnabled"], bool):
        raise Invalid("audioEnabled must be true/false when present")
    if "batchCount" in m:
        if not is_int(m["batchCount"]) or m["batchCount"] < 0:
            raise Invalid(f"batchCount must be a non-negative integer, got {m['batchCount']!r}")
        if m["endedAtUtc"] is None and m["recovered"] is not True:
            raise Invalid("Stop copy (batchCount present) needs endedAtUtc set or recovered true")
    check_strings(m)
    return "stop" if "batchCount" in m else "start"


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


class TooLarge(ValueError):
    pass


def gunzip_one_member(raw, limit):
    """Strict gzip decode: exactly one member, no trailing bytes, at most `limit` bytes out.
    Raises TooLarge(reason) past the limit, ValueError(reason) for anything else."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = d.decompress(raw, limit + 1)
    except zlib.error as e:
        raise ValueError(f"gzip decode failed: {e}")
    if len(out) > limit:
        raise TooLarge(f"decompressed body larger than {limit} bytes")
    if not d.eof:
        raise ValueError("gzip decode failed: truncated gzip stream")
    if d.unused_data:
        if d.unused_data[:2] == b"\x1f\x8b":
            raise ValueError("multiple gzip members are not accepted")
        raise ValueError(f"{len(d.unused_data)} bytes of trailing data after the gzip stream")
    return out


def decode_body(raw, limit):
    """Returns (JSON bytes, was gzip). Decided by the gzip magic bytes, not by Content-Encoding,
    as the ingest function. Raises TooLarge past `limit`, ValueError for broken gzip."""
    if raw[:2] == b"\x1f\x8b":
        return gunzip_one_member(raw, limit), True
    if len(raw) > limit:
        raise TooLarge(f"decompressed body larger than {limit} bytes")
    return raw, False


def parse_json(body):
    """JSON with NaN, Infinity and out-of-range numbers rejected. Raises ValueError."""
    try:
        return json.loads(body.decode("utf-8"), parse_constant=_reject_constant,
                          parse_float=_parse_float)
    except (UnicodeDecodeError, ValueError) as e:
        raise ValueError(f"invalid JSON: {e}")
    except RecursionError:
        raise ValueError("invalid JSON: nested too deeply")


def not_gzip_reason(json_error):
    return f"body is neither gzip (no 1f 8b magic bytes) nor valid JSON ({json_error})"


class State:
    def __init__(self, key, out, fail_every, dup_status):
        self.key = key
        self.out = out
        self.fail_every = fail_every
        self.dup_status = dup_status
        self.lock = threading.Lock()
        self.sessions = {}      # sessionId -> set(batchSeq) accepted
        self.meta = {}          # sessionId -> {"start": bool, "stop": bool, "batchCount": int|None}
        self.duplicates = 0
        self.meta_duplicates = 0
        self.rejects = {}       # "status category" -> [count, first reason]
        self.ingest_count = 0

    def reject(self, status, category, reason):
        with self.lock:
            k = f"{status} {category}"
            entry = self.rejects.setdefault(k, [0, reason])
            entry[0] += 1

    @staticmethod
    def _seq_list(seqs, limit=20):
        s = ", ".join(str(x) for x in seqs[:limit])
        return s + (f", ... ({len(seqs)} total)" if len(seqs) > limit else "")

    def summary(self):
        with self.lock:
            lines = ["", "== mock ingest summary =="]
            total = sum(len(s) for s in self.sessions.values())
            lines.append(f"unique batches: {total} in {len(self.sessions)} session(s); "
                         f"duplicates answered {self.dup_status}: {self.duplicates}")
            n_start = sum(1 for m in self.meta.values() if m["start"])
            n_stop = sum(1 for m in self.meta.values() if m["stop"])
            lines.append(f"session metadata: {n_start} start, {n_stop} stop; "
                         f"repeats answered {self.dup_status}: {self.meta_duplicates}")
            for sid in sorted(set(self.sessions) | set(self.meta)):
                seqs = self.sessions.get(sid, set())
                meta = self.meta.get(sid, {"start": False, "stop": False, "batchCount": None})
                count = meta["batchCount"]
                parts = [f"{len(seqs)} batches"]
                if seqs:
                    parts[0] += f", batchSeq {min(seqs)}..{max(seqs)}"
                if count is not None:
                    missing = [i for i in range(count) if i not in seqs]
                    parts.append(f"batchCount {count}")
                    parts.append(f"missing {len(missing)}" + (f" [{self._seq_list(missing)}]" if missing else ""))
                    extra = sorted(x for x in seqs if x >= count)
                    if extra:
                        parts.append(f"beyond batchCount [{self._seq_list(extra)}]")
                else:
                    parts.append("batchCount unknown")
                    if seqs:
                        holes = (max(seqs) - min(seqs) + 1) - len(seqs)
                        if holes:
                            parts.append(f"{holes} missing in between")
                parts.append(f"meta start={'yes' if meta['start'] else 'no'} "
                             f"stop={'yes' if meta['stop'] else 'no'}")
                lines.append(f"  {sid}: " + ", ".join(parts))
            n_rej = sum(c for c, _ in self.rejects.values())
            lines.append(f"rejects: {n_rej}")
            for k, (c, first) in sorted(self.rejects.items()):
                lines.append(f"  {k}: {c}  (e.g. {first})")
            return "\n".join(lines)


def _safe_name(sid):
    return re.sub(r"[^A-Za-z0-9._-]", "_", sid)[:128]


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
        return self._send(404, {"message": "Not Found"})  # unknown routes

    def _drain_and_not_found(self):
        self._drain_body()
        self._not_found()

    # Known paths with another method are 404 too (Azure Functions method-restricted routes).
    do_GET = do_DELETE = do_PATCH = _drain_and_not_found

    def _decode_json_body(self, raw, n):
        """Steps 0-4 shared by both routes. Returns the parsed JSON, or None after sending the
        rejection."""
        st = self.state
        with st.lock:
            st.ingest_count += 1
            nth = st.ingest_count
        if st.fail_every and nth % st.fail_every == 0:
            self._reject(503, "simulated outage", f"simulated outage (request #{nth})")
            return None
        # 1. device key first (the function authenticates before touching the body)
        if not self._key_ok():
            self._reject(401, "bad key", "bad x-device-key")
            return None
        if raw is None:
            if n > MAX_BODY:
                self._reject(413, "too large", f"body larger than {MAX_BODY} bytes")
            else:
                self._reject(400, "content-length", "missing/invalid Content-Length")
            return None
        # 2. headers (Content-Encoding is not checked: the magic bytes decide, as in the function)
        if not (self.headers.get("Content-Type") or "").lower().startswith("application/json"):
            self._reject(400, "content-type", "Content-Type must be application/json")
            return None
        # 3. gunzip (200 KB decompressed limit, as the ingest function)
        try:
            body, was_gzip = decode_body(raw, MAX_INFLATED)
        except TooLarge as e:
            self._reject(413, "too large", str(e))
            return None
        except ValueError as e:
            self._reject(400, "gzip", str(e))
            return None
        # 4. JSON
        try:
            return parse_json(body)
        except ValueError as e:
            self._reject(400, "json", str(e) if was_gzip else not_gzip_reason(str(e)))
            return None

    def do_PUT(self):
        path = self.path.split("?", 1)[0]
        raw, n = self._drain_body()
        path_id = path[len(SESSIONS_PREFIX):] if path.startswith(SESSIONS_PREFIX) else ""
        if not SESSION_ID_RE.match(path_id):
            return self._not_found()
        st = self.state
        m = self._decode_json_body(raw, n)
        if m is None:
            return
        ids = f"sid={path_id[:8]}"
        # 5. schema
        try:
            phase = validate_session_meta(m, path_id)
        except Invalid as e:
            return self._reject(400, "session schema", str(e), ids)
        count = m.get("batchCount")
        info = f"{ids} phase={phase} batchCount={count if count is not None else '-'}"
        # 6. idempotency header: must name the same phase as the body
        idem = self.headers.get("x-idempotency-key")
        if idem is not None and idem != f"{path_id}:meta-{phase}":
            return self._reject(400, "idempotency-key",
                                f"x-idempotency-key {idem!r} != '{path_id}:meta-{phase}' "
                                f"(batchCount {'present' if phase == 'stop' else 'absent'})", info)
        with st.lock:
            meta = st.meta.setdefault(path_id, {"start": False, "stop": False, "batchCount": None})
            dup = meta[phase]
            meta[phase] = True
            if phase == "stop":
                meta["batchCount"] = count
            if dup:
                st.meta_duplicates += 1
            # Latest metadata, but a late (retried) Start copy never replaces the Stop copy.
            if st.out and (phase == "stop" or not meta["stop"]):
                folder = os.path.join(st.out, "sessions")
                os.makedirs(folder, exist_ok=True)
                with open(os.path.join(folder, f"{_safe_name(path_id)}.json"), "w", encoding="utf-8") as fh:
                    json.dump(m, fh, indent=2, sort_keys=True)
        reply = {"ok": True, "sessionId": path_id, "phase": phase}
        if dup:
            reply["duplicate"] = True
            return self._send(st.dup_status, reply, info + " duplicate")
        self._send(201, reply, info)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        raw, n = self._drain_body()
        if path != INGEST_PATH:
            return self._not_found()
        st = self.state
        probe = self.headers.get("x-probe") == "1"
        b = self._decode_json_body(raw, n)
        if b is None:
            return

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
                    with open(os.path.join(st.out, f"{_safe_name(sid)}.jsonl"), "a", encoding="utf-8") as fh:
                        fh.write(json.dumps(b, separators=(",", ":")) + "\n")
        if dup:
            return self._send(st.dup_status, {"ok": True, "duplicate": True, "sessionId": sid,
                                              "batchSeq": seq}, info + " duplicate")
        self._send(201, {"ok": True, "sessionId": sid, "batchSeq": seq}, info)


def _sigterm(signum, frame):
    raise KeyboardInterrupt


def main():
    ap = argparse.ArgumentParser(description="Mock ingest server: POST /api/ingest + PUT /api/ingest/sessions/{id} (stdlib only).")
    ap.add_argument("--port", type=int, default=8080, help="0 = pick a free port")
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address (default loopback). Use 0.0.0.0 to accept the phone over Wi-Fi; "
                         "that requires --key (or --allow-any-key).")
    ap.add_argument("--allow-any-key", action="store_true",
                    help="accept any device key even when listening on the network (not recommended)")
    ap.add_argument("--key", default=None, help="require this x-device-key (default: accept any)")
    ap.add_argument("--out", default=None, help="append accepted batches to DIR/<sessionId>.jsonl; "
                    "latest session metadata to DIR/sessions/<sessionId>.json")
    ap.add_argument("--fail-every", type=int, default=0, metavar="N",
                    help="return 503 for every Nth ingest request (POST batch or PUT metadata)")
    ap.add_argument("--dup-status", type=int, choices=(200, 409), default=200,
                    help="status for a repeated batch or metadata phase; the backend answers 200 (default)")
    a = ap.parse_args()
    if a.host not in ("127.0.0.1", "localhost", "::1") and not a.key and not a.allow_any_key:
        ap.error("listening on the network without --key lets anyone on the Wi-Fi inject data; "
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
