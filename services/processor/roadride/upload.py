"""Reading a laptop upload (plan §7 "Fallback: a trip that never reached the cloud").

`tools/upload` copies a session folder to the `sessions` container under `<sessionId>/` and writes
`_complete.json` last; Event Grid then puts a message on the session-ready queue. The manifest
(tools/upload/README.md) lists every file with its size and SHA-256:

    {"sessionId": "...", "uploadedAtUtc": "...", "tool": "...",
     "files": {"session.json": {"bytes": 1234, "sha256": "..."}, "device_motion.csv": {...}, ...}}

A folder is used only when every listed file is there with that size and hash, so a half-finished
re-upload or a hand-edited file never replaces a trip's results.

The folder becomes the same 2-second batches the phone (and tools/replay) sends: windows of `t_up`
from `startUptimeSec`, each with the clock offset of its first row, so the finalize job runs the very
pipeline it runs on the live archive (a test checks the two give the same results).
"""

from __future__ import annotations

import csv
import datetime as dt
import hashlib
import io
import json
import logging
import math
import pathlib
import re
from dataclasses import dataclass, field
from typing import Protocol

import numpy as np

from .live import BatchFacts, Fix, Label, from_ms

log = logging.getLogger(__name__)

MANIFEST = "_complete.json"
REQUIRED = ("session.json", "device_motion.csv", "location.csv")
BATCH_S = 2.0  # the app's batch window (spec §6)
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")  # as the ingest function: it is a blob prefix

MOTION_COLS = ("ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z")
LOCATION_COLS = ("lat", "lon", "h_acc", "speed", "course")
# quality.streams of an uploaded trip: the live path's names for the streams a batch carries (the read
# API maps them to file names), the file names for the others. Location comes from the fixes.
EXTRA_STREAMS = {
    "accelRaw": ("accel_raw.csv", 100.0),
    "gyroRaw": ("gyro_raw.csv", 100.0),
    "mag_raw": ("mag_raw.csv", 50.0),
    "altimeter": ("altimeter.csv", 1.0),  # CMAltimeter: about once a second, as in the read API and the mock
    "abs_altitude": ("abs_altitude.csv", None),
    "audioLevel": ("audio_level.csv", 10.0),
}


class UploadInvalid(Exception):
    """The folder can't be used as it is (missing or changed files); a new upload fixes it."""


class Uploads(Protocol):
    def list(self, session_id: str) -> dict[str, int]: ...  # file name under <sessionId>/ -> bytes
    def read(self, session_id: str, name: str) -> bytes: ...


class BlobUploads:
    """The `sessions` container, logged in with the job's managed identity (Storage Blob Data Reader)."""

    def __init__(self, endpoint: str, container: str):
        from azure.identity import DefaultAzureCredential
        from azure.storage.blob import ContainerClient

        self._client = ContainerClient(endpoint, container,
                                       credential=DefaultAzureCredential(exclude_interactive_browser_credential=True))

    def list(self, session_id: str) -> dict[str, int]:
        prefix = f"{session_id}/"
        return {b.name[len(prefix):]: int(b.size) for b in self._client.list_blobs(name_starts_with=prefix)}

    def read(self, session_id: str, name: str) -> bytes:
        return self._client.download_blob(f"{session_id}/{name}").readall()


class DirUploads:
    """A local copy of the `sessions` container (tests, `UPLOAD_DIR` for local runs, and the output of
    `tools/upload --dry-run`)."""

    def __init__(self, root: str | pathlib.Path):
        self.root = pathlib.Path(root)

    def list(self, session_id: str) -> dict[str, int]:
        folder = self.root / session_id
        return {p.name: p.stat().st_size for p in folder.iterdir() if p.is_file()} if folder.is_dir() else {}

    def read(self, session_id: str, name: str) -> bytes:
        return (self.root / session_id / name).read_bytes()


def has_upload(uploads: Uploads, session_id: str) -> bool:
    return MANIFEST in uploads.list(session_id)


# --- Manifest -------------------------------------------------------------------------------

def check_manifest(uploads: Uploads, session_id: str) -> dict[str, dict]:
    """The manifest's file list, once every listed file is there with its size. Raises UploadInvalid."""
    if not SESSION_ID_RE.match(session_id):
        raise UploadInvalid(f"bad session folder name {session_id[:80]!r}")
    present = uploads.list(session_id)
    if MANIFEST not in present:
        raise UploadInvalid("no _complete.json")
    try:
        doc = json.loads(uploads.read(session_id, MANIFEST))
    except (ValueError, UnicodeDecodeError) as e:
        raise UploadInvalid(f"_complete.json is not JSON: {e}") from None
    files = doc.get("files") if isinstance(doc, dict) else None
    if not isinstance(files, dict) or doc.get("sessionId") != session_id:
        raise UploadInvalid("_complete.json has no file list for this session")
    for name in REQUIRED:
        if name not in files:
            raise UploadInvalid(f"{name} is not in the upload")
    for name, info in files.items():
        if not isinstance(info, dict) or type(info.get("bytes")) is not int or \
                not isinstance(info.get("sha256"), str):
            raise UploadInvalid(f"_complete.json: bad entry for {name!r}")
        if name not in present:
            raise UploadInvalid(f"{name} is missing")
        if present[name] != info["bytes"]:
            raise UploadInvalid(f"{name} has {present[name]} bytes, the manifest says {info['bytes']}")
    return files


def _read_checked(uploads: Uploads, session_id: str, files: dict, name: str) -> bytes | None:
    if name not in files:
        return None
    data = uploads.read(session_id, name)
    if len(data) != files[name]["bytes"] or hashlib.sha256(data).hexdigest() != files[name]["sha256"].lower():
        raise UploadInvalid(f"{name} changed since the upload (size or SHA-256 differs)")
    return data


# --- CSV ------------------------------------------------------------------------------------

def read_columns(data: bytes, numeric: tuple[str, ...], text: tuple[str, ...] = ()) -> dict[str, np.ndarray]:
    """Columns of one of the app's CSV files (spec §4), with `t_up` and `t_utc_ms` always included.
    Numbers are float64 with NaN for an empty field (the app writes non-finite values that way);
    rows without a `t_up` and torn or truncated rows (after a crash) are dropped. Text columns are
    object arrays with None for an empty field."""
    numeric = ("t_up", "t_utc_ms") + tuple(c for c in numeric if c not in ("t_up", "t_utc_ms"))
    try:
        out = _read_arrow(data, numeric, text)
    except Exception:  # noqa: BLE001 - a value Arrow can't parse: take the slow, forgiving path
        out = _read_stdlib(data, numeric, text)
    keep = np.isfinite(out["t_up"])
    return {k: v[keep] for k, v in out.items()}


def _read_arrow(data: bytes, numeric, text) -> dict[str, np.ndarray]:
    import pyarrow as pa
    import pyarrow.csv as pcsv

    end = data.find(b"\n")
    header = data[: end if end >= 0 else len(data)].decode("utf-8", "replace").strip().split(",")
    wanted = [c for c in (*numeric, *text) if c in header]
    # Streamed in blocks, one thread: a 3-hour device_motion.csv (≈ 160 MB) would otherwise need
    # several times its size at once in the 2 GiB job.
    reader = pcsv.open_csv(
        io.BytesIO(data),
        read_options=pcsv.ReadOptions(use_threads=False, block_size=4 << 20),
        parse_options=pcsv.ParseOptions(invalid_row_handler=lambda row: "skip"),
        convert_options=pcsv.ConvertOptions(
            include_columns=wanted,
            column_types={**{c: pa.float64() for c in numeric}, **{c: pa.string() for c in text}},
            strings_can_be_null=True, quoted_strings_can_be_null=False),
    )
    parts: dict[str, list] = {c: [] for c in wanted}
    n = 0
    for block in reader:
        n += block.num_rows
        for c in wanted:
            col = block.column(c)
            parts[c].append(col.to_numpy(zero_copy_only=False) if c in numeric else col.to_pylist())
    out = {}
    for c in numeric:
        out[c] = np.concatenate(parts[c]).astype(float, copy=False) if c in wanted and parts[c] else np.full(n, np.nan)
    for c in text:
        out[c] = np.array([v for part in parts[c] for v in part] if c in wanted else [None] * n, dtype=object)
    return out


def _read_stdlib(data: bytes, numeric, text) -> dict[str, np.ndarray]:
    rows = csv.reader(io.StringIO(data.decode("utf-8", "replace")))
    header = next(rows, [])
    idx = {c: i for i, c in enumerate(header)}
    cols: dict[str, list] = {c: [] for c in (*numeric, *text)}
    while True:
        try:
            r = next(rows)
        except StopIteration:
            break
        except csv.Error:  # a torn last line
            break
        if len(r) != len(header):
            continue
        for c in numeric:
            try:
                v = float(r[idx[c]]) if c in idx else math.nan
            except ValueError:
                v = math.nan
            cols[c].append(v)
        for c in text:
            cols[c].append((r[idx[c]] or None) if c in idx else None)
    return {**{c: np.asarray(cols[c], dtype=float) for c in numeric},
            **{c: np.array(cols[c], dtype=object) for c in text}}


def _sorted(cols: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    if len(cols["t_up"]) < 2 or bool(np.all(np.diff(cols["t_up"]) >= 0)):
        return cols
    order = np.argsort(cols["t_up"], kind="stable")  # the app appends in arrival order
    return {k: v[order] for k, v in cols.items()}


# --- The trip -------------------------------------------------------------------------------

@dataclass
class UploadedTrip:
    session_id: str
    meta: dict  # session.json without personal fields
    batches: list[BatchFacts]
    streams: dict[str, dict] = field(default_factory=dict)  # quality.streams for the extra CSV files
    incomplete: bool = False  # the app crashed or never wrote endedAtUtc


def _stream_quality(t_up: np.ndarray, expected_hz: float | None) -> dict:
    from .finalize import stream_quality

    return stream_quality(t_up.tolist(), expected_hz)


def _clean_meta(meta: dict) -> dict:
    meta = json.loads(json.dumps(meta))
    if isinstance(meta.get("people"), dict):
        meta["people"].pop("raterName", None)  # personal data stays on the phone (spec §6.2)
    return meta


def load(uploads: Uploads, session_id: str) -> UploadedTrip:
    """The uploaded folder as live-like batches. Raises UploadInvalid."""
    files = check_manifest(uploads, session_id)
    try:
        meta = json.loads(_read_checked(uploads, session_id, files, "session.json"))
    except (ValueError, UnicodeDecodeError) as e:
        raise UploadInvalid(f"session.json is not JSON: {e}") from None
    if not isinstance(meta, dict) or meta.get("sessionId") != session_id:
        raise UploadInvalid("session.json belongs to another session")
    meta = _clean_meta(meta)

    dm = _sorted(read_columns(_read_checked(uploads, session_id, files, "device_motion.csv"), MOTION_COLS))
    if not len(dm["t_up"]):
        raise UploadInvalid("device_motion.csv has no samples")
    loc = _sorted(read_columns(_read_checked(uploads, session_id, files, "location.csv"), LOCATION_COLS))
    lab_data = _read_checked(uploads, session_id, files, "labels.csv")
    lab = _sorted(read_columns(lab_data, (), ("type", "value", "note"))) if lab_data else \
        {"t_up": np.zeros(0), "t_utc_ms": np.zeros(0), "type": np.zeros(0, dtype=object),
         "value": np.zeros(0, dtype=object), "note": np.zeros(0, dtype=object)}

    streams = {}
    clocks = []  # every stream's (t_up, t_utc_ms), for the windows' UTC offsets as tools/replay takes them
    for name, (fname, hz) in EXTRA_STREAMS.items():
        data = _read_checked(uploads, session_id, files, fname)
        if data is not None:
            cols = _sorted(read_columns(data, ()))
            streams[name] = _stream_quality(cols["t_up"], hz)
            clocks.append(cols)
    data = _read_checked(uploads, session_id, files, "device.csv")
    if data is not None:
        clocks.append(_sorted(read_columns(data, ())))

    batches = build_batches(session_id, meta, dm, loc, lab, clocks)
    ended = meta.get("endedAtUtc")
    return UploadedTrip(session_id=session_id, meta=meta, batches=batches, streams=streams,
                        incomplete=meta.get("recovered") is True or not ended)


def _non_negative(v: float) -> float | None:
    return float(v) if math.isfinite(v) and v >= 0 else None


def build_batches(session_id: str, meta: dict, dm: dict, loc: dict, lab: dict,
                  clocks: list[dict] = ()) -> list[BatchFacts]:
    """2-second windows of `t_up`, as the app builds them (and tools/replay rebuilds them): from
    `startUptimeSec` (or the first motion sample, if that is earlier), up to the last motion, fix or
    label; each window's UTC offset from its first row with a UTC time in any stream (`clocks` are
    the other CSV files), else the window before's."""
    first_up = float(dm["t_up"][0])
    start_up = meta.get("startUptimeSec")
    if not isinstance(start_up, (int, float)) or isinstance(start_up, bool) or not math.isfinite(start_up) \
            or start_up > first_up:
        start_up = first_up
    last_up = max(float(a["t_up"][-1]) for a in (dm, loc, lab) if len(a["t_up"]))
    windows = max(1, math.ceil((last_up + 1e-6 - start_up) / BATCH_S - 1e-9))

    def cut(a: dict, t0: float, t1: float) -> slice:
        return slice(int(np.searchsorted(a["t_up"], t0, "left")), int(np.searchsorted(a["t_up"], t1, "left")))

    device_id = str(meta.get("deviceId") or "") or None
    zeros = np.nan_to_num  # the app sends a non-finite sensor value as 0 in a live batch
    offset_ms = None
    out = []
    for k in range(windows):
        t0 = start_up + k * BATCH_S
        t1 = t0 + BATCH_S
        sd, sl, sb = cut(dm, t0, t1), cut(loc, t0, t1), cut(lab, t0, t1)
        firsts = []
        for a, sl_ in [(dm, sd), (loc, sl), (lab, sb)] + [(c, cut(c, t0, t1)) for c in clocks]:
            ok = np.flatnonzero(np.isfinite(a["t_utc_ms"][sl_]))
            if len(ok):
                firsts.append((float(a["t_up"][sl_][ok[0]]), float(a["t_utc_ms"][sl_][ok[0]])))
        if firsts:
            up, utc = min(firsts)
            offset_ms = utc - up * 1000.0
        if offset_ms is None:  # nothing with a UTC time yet: look ahead for the first one
            ahead = [a["t_utc_ms"] - a["t_up"] * 1000.0 for a in (dm, loc, lab)]
            vals = np.concatenate(ahead)
            vals = vals[np.isfinite(vals)]
            if not len(vals):
                raise UploadInvalid("no t_utc_ms in device_motion, location or labels")
            offset_ms = float(vals[0])
        t0_utc_ms = round(t0 * 1000.0 + offset_ms)
        t0_utc = from_ms(t0_utc_ms)
        clock_offset = t0_utc_ms / 1000.0 - t0

        fixes = []
        for i in range(sl.start, sl.stop):
            lat, lon = loc["lat"][i], loc["lon"][i]
            if not (math.isfinite(lat) and math.isfinite(lon)):
                continue
            utc = loc["t_utc_ms"][i]
            utc = utc if math.isfinite(utc) else loc["t_up"][i] * 1000.0 + offset_ms
            fixes.append(Fix(t=from_ms(round(utc)), lat=float(lat), lon=float(lon),
                             speed_ms=_non_negative(loc["speed"][i]), course_deg=_non_negative(loc["course"][i]),
                             h_acc_m=_non_negative(loc["h_acc"][i])))
        labels = []
        for i in range(sb.start, sb.stop):
            if not lab["type"][i]:
                continue
            utc = lab["t_utc_ms"][i]
            t = from_ms(utc) if math.isfinite(utc) else t0_utc + dt.timedelta(seconds=float(lab["t_up"][i] - t0))
            labels.append(Label(t=t, type=str(lab["type"][i]), value=lab["value"][i], note=lab["note"][i]))

        motion_t = dm["t_up"][sd]
        newest = max([float(motion_t[-1]) - t0] if len(motion_t) else [0.0])
        end = t0_utc + dt.timedelta(seconds=newest)
        if fixes:
            end = max(end, max(f.t for f in fixes))
        out.append(BatchFacts(
            session_id=session_id, device_id=device_id, batch_seq=k, source="upload",
            t0_utc=t0_utc, end_utc=end,
            sample_counts={"deviceMotion": len(motion_t), "location": len(fixes), "labels": len(labels)},
            fixes=fixes, labels=labels, clock_offset=clock_offset,
            motion_t=motion_t,
            motion_ua=zeros(np.column_stack([dm[c][sd] for c in MOTION_COLS[0:3]])),
            motion_g=zeros(np.column_stack([dm[c][sd] for c in MOTION_COLS[3:6]])),
            motion_rr=zeros(np.column_stack([dm[c][sd] for c in MOTION_COLS[6:9]])),
        ))
    return out
