"""The ingest contract: body decoding and schema checks.

Ported from src/mobile-ios/tools/mock_ingest_server.py, the server the iPhone app was built and tested
against. Keep the two in step: tests/test_parity.py runs the same cases through both.

Pure standard library, so it is testable without Azure.
"""

from __future__ import annotations

import datetime as dt
import json
import math
import re
import zlib

MAX_BODY = 20 * 1024 * 1024  # compressed (413)
MAX_INFLATED = 200 * 1024  # decompressed (413), plan §5

# String limits (400). The processor keeps IDs and label types in primary keys (a btree row is at
# most 2704 bytes) and every other string in text/jsonb, which can't hold NUL or a lone surrogate.
# The app sends UUIDs, label types of at most 15 characters and short free text; nothing it sends
# comes near these.
MAX_ID_LEN = 128  # deviceId (also the Event Hubs partition key, at most 128 characters)
MAX_LABEL_TYPE_LEN = 64
MAX_TEXT_LEN = 2000  # any other string or object key: notes, vehicle, mount, ...
_BAD_CHARS = re.compile(r"[\x00\ud800-\udfff]")

# Stricter than the mock, which accepts any non-empty string: the session ID becomes part of a blob
# path, so it must not contain "/" or "..". The app uses UUIDs.
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

REQUIRED_KEYS = ["schemaVersion", "sessionId", "deviceId", "batchSeq", "t0Utc", "t0Up", "units",
                 "deviceMotion", "accelRaw", "gyroRaw", "location", "altimeter", "audioLevel",
                 "labels", "device"]
EXPECTED_UNITS = {"accel": "g", "gyro": "rad/s", "speed": "m/s", "pressure": "kPa"}
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
T0_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")

PROBE_PREFIX = "probe request"


class Invalid(Exception):
    """The body is well-formed JSON but breaks the contract (400)."""


class TooLarge(ValueError):
    """The body is over a size limit (413)."""


def is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_int(v) -> bool:
    return type(v) is int  # excludes bool and float (1.0)


# --- Decoding ---------------------------------------------------------------------------

def gunzip_one_member(raw: bytes, limit: int = MAX_INFLATED) -> bytes:
    """Strict gzip decode: exactly one member, no trailing bytes, at most `limit` bytes out."""
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


def is_gzip(raw: bytes) -> bool:
    return raw[:2] == b"\x1f\x8b"


def decode_body(raw: bytes, limit: int = MAX_INFLATED) -> tuple[bytes, bool]:
    """Returns (JSON bytes, was gzip). Decided by the gzip magic bytes, not by Content-Encoding:
    the Functions host may inflate the body itself and drop the header (plan §5, "works either
    way"). Raises TooLarge past `limit`, ValueError for broken gzip."""
    if is_gzip(raw):
        return gunzip_one_member(raw, limit), True
    if len(raw) > limit:
        raise TooLarge(f"decompressed body larger than {limit} bytes")
    return raw, False


def not_gzip_reason(json_error: str) -> str:
    """The 400 reason for a body that is neither gzip nor JSON."""
    return f"body is neither gzip (no 1f 8b magic bytes) nor valid JSON ({json_error})"


def _reject_constant(name):
    raise ValueError(f"non-finite number {name} not allowed")


def _parse_float(s):
    v = float(s)
    if not math.isfinite(v):
        raise ValueError(f"number {s} out of range")
    return v


def parse_json(body: bytes):
    """JSON with NaN, Infinity and out-of-range numbers rejected. Raises ValueError."""
    try:
        return json.loads(body.decode("utf-8"), parse_constant=_reject_constant,
                          parse_float=_parse_float)
    except UnicodeDecodeError as e:
        raise ValueError(f"invalid JSON: {e}")
    except ValueError as e:
        raise ValueError(f"invalid JSON: {e}")
    except RecursionError:
        raise ValueError("invalid JSON: nested too deeply")


# --- Schema -------------------------------------------------------------------------------

def _short(path: str) -> str:
    return path if len(path) <= 80 else path[:77] + "..."


def check_strings(doc, limit: int = MAX_TEXT_LEN) -> None:
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


def validate_batch(b) -> None:
    """Raises Invalid(reason) if the batch does not match the schemaVersion 1 contract."""
    if not isinstance(b, dict):
        raise Invalid("body is not a JSON object")
    if b.get("probe") is True:
        raise Invalid(f"{PROBE_PREFIX} (connectivity test): not an ingest batch, nothing stored - "
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
    if not SESSION_ID_RE.match(b["sessionId"]):
        raise Invalid("sessionId must be 1-128 characters from A-Z a-z 0-9 _ -")
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
    for k in ("eventType", "source"):
        if k in b and (not isinstance(b[k], str) or not b[k]):
            raise Invalid(f"{k} must be a non-empty string when present")
    if "t0UtcMs" in b and not is_int(b["t0UtcMs"]):
        raise Invalid("t0UtcMs must be an integer (Unix ms) when present")
    if "fieldUnits" in b and (not isinstance(b["fieldUnits"], dict)
                              or not all(isinstance(k, str) and isinstance(v, str)
                                         for k, v in b["fieldUnits"].items())):
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
            if not isinstance(h, dict) or not is_int(h.get("tUtcMs")) \
                    or not all(is_num(h.get(k)) for k in HEADING_NUM):
                raise Invalid(f"heading[{i}] needs int tUtcMs and numeric {', '.join(HEADING_NUM)}")
    if "activity" in b:
        if not isinstance(b["activity"], list):
            raise Invalid("activity must be an array")
        for i, a in enumerate(b["activity"]):
            if (not isinstance(a, dict) or not is_num(a.get("t")) or not is_int(a.get("startUtcMs"))
                    or not all(isinstance(a.get(k), bool) for k in ACTIVITY_BOOL)
                    or not is_int(a.get("confidence")) or a["confidence"] not in (0, 1, 2)):
                raise Invalid(f"activity[{i}] needs numeric t, int startUtcMs, booleans "
                              f"{', '.join(ACTIVITY_BOOL)}, confidence 0|1|2")

    if not isinstance(b["location"], list):
        raise Invalid("location must be an array")
    for i, loc in enumerate(b["location"]):
        if not isinstance(loc, dict):
            raise Invalid(f"location[{i}] must be an object")
        if "isSimulated" in loc and loc["isSimulated"] is not None \
                and not isinstance(loc["isSimulated"], bool):
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


def validate_session_meta(m, path_id: str) -> str:
    """Validates session.json for PUT /api/ingest/sessions/<path_id>.
    Returns "stop" when batchCount is present, else "start". Raises Invalid(reason)."""
    if not isinstance(m, dict):
        raise Invalid("body is not a JSON object")
    if not isinstance(m.get("sessionId"), str) or not m["sessionId"]:
        raise Invalid("sessionId must be a non-empty string")
    if m["sessionId"] != path_id:
        raise Invalid(f"body sessionId {m['sessionId']!r} != path sessionId {path_id!r}")
    # Required since the device key is bound to it; every app build that sends metadata sets it.
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
