"""The finalize job (plan §5 "Finalize job", §7 "When the trip ends").

Started by KEDA when "session ready" lands in the Service Bus queue. For each message it:
1. reads the trip's whole raw archive from the `lake` container (`raw/session=<id>/`: every batch
   the ingest function accepted, plus the Start and Stop copies of session.json), or the session
   folder a laptop uploaded to the `sessions` container (upload.py). A complete upload always wins,
   also for a message from the stream processor (a live backlog that reopened the trip later): it
   has every sample, while the live path may have lost batches (plan §5, §7);
2. runs the same signal pipeline as the stream processor over the complete trip in one pass, batch
   by batch in sequence order, so late batches count too and the filters restart only at real holes;
3. writes the trip's samples and results as Parquet to `lake` (`processed/session=<id>/`);
4. replaces the trip's live results (series, events) and writes one segment observation per H3
   cell pass, the trip's quality measurements and status `complete`, in one transaction;
5. rebuilds the aggregates (aggregate.rebuild), then completes the message.

Everything it writes is deleted or overwritten per trip, so a redelivered or resent message is
harmless. An upload that doesn't match its `_complete.json` is dead-lettered with the reason; a new
upload sends a new message.

Thresholds in the quality checks are PROVISIONAL, like the pothole threshold in dsp.py.
"""

from __future__ import annotations

import gzip
import io
import json
import logging
import math
import os
import pathlib
import re
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Protocol

import numpy as np
from psycopg import Connection
from psycopg.types.json import Jsonb

from . import aggregate, quality, upload
from .dsp import Event, Pipeline, SeriesPoint
from .live import BatchFacts, Fix, parse_batch, parse_session
from .store import Store, from_epoch

log = logging.getLogger(__name__)

H3_RESOLUTION = aggregate.H3_RESOLUTION
WINDOW_S = 0.2  # session_series spacing (dsp.SERIES_EVERY at 100 Hz)
MOVING_SPEED_MS = 1.0  # windows slower than this don't count for a pass's roughness (as the mock)
MIN_MOVING_WINDOWS = 3
MAX_FIX_GAP_S = 10.0  # no position between two fixes further apart than this
FIX_EDGE_S = 2.0  # a window this close before the first / after the last fix still gets a position
MOTION_HZ = 100.0
GPS_GOOD_HACC_M = 20.0  # PROVISIONAL: a fix worse than this counts as poor GPS
# Trip distance, the same rule as the read API's TRACK_STATS_SQL: only fixes with a known accuracy of at
# most DISTANCE_MAX_HACC_M (the read API's MAX_HACC_M), and a step only counts when either end moves
# at least DISTANCE_MIN_SPEED_MS (or neither has a speed). Parked, the position jitters by metres
# while the Doppler speed stays near 0: 10 minutes of 3 m jitter added 3 km before.
DISTANCE_MAX_HACC_M = 50.0
DISTANCE_MIN_SPEED_MS = 1.0

MAX_MESSAGES_PER_RUN = 20  # KEDA starts one execution per message; draining a few more is cheaper
TIME_BUDGET_S = 20 * 60  # stop taking new messages well before the job's 30-minute limit
DOWNLOAD_THREADS = 16
MAX_DELIVERIES = 5  # the queue's max_delivery_count (infra/modules/messaging)

_SUBJECT_RE = re.compile(r"/containers/[^/]+/blobs/([^/]+)/_complete\.json$")


# --- The raw archive ------------------------------------------------------------------------

class Archive(Protocol):
    def list_names(self, session_id: str) -> list[str]: ...
    def read(self, name: str) -> bytes: ...
    def write(self, name: str, data: bytes) -> None: ...


class BlobArchive:
    """The `lake` container, logged in with the job's managed identity."""

    def __init__(self, endpoint: str, container: str):
        from azure.identity import DefaultAzureCredential
        from azure.storage.blob import ContainerClient

        self._client = ContainerClient(endpoint, container,
                                       credential=DefaultAzureCredential(exclude_interactive_browser_credential=True))

    def list_names(self, session_id: str) -> list[str]:
        return [b.name for b in self._client.list_blobs(name_starts_with=f"raw/session={session_id}/")]

    def read(self, name: str) -> bytes:
        # Ingest stores the gzip with Content-Encoding: gzip, and the SDK inflates such blobs by
        # default; load_trip expects the stored gzip bytes, as DirArchive returns them.
        return self._client.download_blob(name, decompress=False).readall()

    def write(self, name: str, data: bytes) -> None:
        self._client.upload_blob(name, data, overwrite=True)


class DirArchive:
    """A local copy of the `lake` container (tests, and `ARCHIVE_DIR` for local runs)."""

    def __init__(self, root: str | pathlib.Path):
        self.root = pathlib.Path(root)

    def list_names(self, session_id: str) -> list[str]:
        folder = self.root / "raw" / f"session={session_id}"
        return sorted(f"raw/session={session_id}/{p.name}" for p in folder.glob("*.json.gz")) \
            if folder.is_dir() else []

    def read(self, name: str) -> bytes:
        return (self.root / name).read_bytes()

    def write(self, name: str, data: bytes) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


@dataclass
class Trip:
    session_id: str
    batches: list[BatchFacts]  # unique batch_seq, ascending
    meta: list[dict]  # session.json copies: Start first, then Stop
    origin: str = "archive"  # the live raw archive, or "upload"
    source: str | None = None  # sessions.source for a trip the database doesn't know yet
    streams: dict[str, dict] = field(default_factory=dict)  # quality.streams beyond motion and location
    incomplete: bool | None = None  # None: from the batch count (live), else known (upload)


def from_upload(t: upload.UploadedTrip) -> Trip:
    return Trip(t.session_id, t.batches, [t.meta], origin="upload", source="upload", streams=t.streams,
                incomplete=t.incomplete)


def load_trip(archive: Archive, session_id: str) -> Trip:
    names = archive.list_names(session_id)

    def fetch(name: str) -> tuple[str, dict]:
        return name, json.loads(gzip.decompress(archive.read(name)))

    with ThreadPoolExecutor(DOWNLOAD_THREADS) as pool:
        docs = list(pool.map(fetch, names))
    batches: dict[int, BatchFacts] = {}
    meta = {}
    for name, doc in docs:
        base = name.rsplit("/", 1)[-1]
        if base.startswith("session-"):
            meta[base] = doc
            continue
        try:
            f = parse_batch(doc)
        except Exception:  # noqa: BLE001 - one unreadable blob mustn't sink the trip
            log.exception("skipping unreadable archive blob %s", name)
            continue
        batches.setdefault(f.batch_seq, f)
    ordered_meta = [meta[k] for k in ("session-start.json.gz", "session-stop.json.gz") if k in meta]
    return Trip(session_id, [batches[k] for k in sorted(batches)], ordered_meta)


# --- One pass over the trip -----------------------------------------------------------------

@dataclass
class TripSignal:
    series: list[SeriesPoint] = field(default_factory=list)  # t in epoch seconds, UTC
    events: list[Event] = field(default_factory=list)
    msdv: float = 0.0
    resets: int = 0
    state: dict | None = None  # the pipeline after the last batch, for batches that arrive later
    last_batch_seq: int | None = None


def fixes_by_window(batches: list[BatchFacts]) -> list[list[tuple[float, float | None]]]:
    """Each batch's GPS fixes as (uptime s, speed), moved to the batch whose window holds the fix's
    time. The app drains fixes by arrival, so a fix that arrives after its window was sent rides in
    the next batch; fed there, the pipeline would take it at that batch's first sample instead of at
    its own time. Uploads (cut by t_up) already put every fix in its own window, so moving them makes
    a trip finalized from the live archive equal the same trip finalized from an upload. A fix
    before the first window stays in the first batch. The live path can't go back: there a late fix
    is approximate."""
    starts = np.array([f.t0_utc.timestamp() - f.clock_offset for f in batches])
    out: list[list[tuple[float, float | None]]] = [[] for _ in batches]
    for f in batches:
        for x in f.fixes:
            t = x.t.timestamp() - f.clock_offset
            k = max(0, int(np.searchsorted(starts, t, side="right")) - 1)
            out[k].append((t, x.speed_ms))
    return out


def run_pipeline(batches: list[BatchFacts]) -> TripSignal:
    """The stream processor's per-batch steps (store.Store._process_signal), without the database:
    the same pipeline, batch by batch, reset at a missing batch, results moved to UTC with each
    batch's own clock offset. A cleanly streamed trip gives the live numbers again, except where a
    GPS fix arrived after its batch was sent (`fixes_by_window`)."""
    pipe = Pipeline()
    out = TripSignal()
    prev = None
    for f, fixes in zip(batches, fixes_by_window(batches)):
        off = f.clock_offset
        res = pipe.feed(
            np.asarray(f.motion_t, dtype=float),
            np.asarray(f.motion_ua, dtype=float).reshape(-1, 3),
            np.asarray(f.motion_g, dtype=float).reshape(-1, 3),
            fixes,
            reset=prev is not None and f.batch_seq != prev + 1,
            rr=np.asarray(f.motion_rr, dtype=float).reshape(-1, 3),
        )
        for p in res.series:
            p.t += off
        for e in res.events:
            e.t += off
        out.series += res.series
        out.events += res.events
        out.resets += int(res.reset)
        prev = f.batch_seq
    if batches:  # the trip is over: potholes still held back for a possible speed bump are final
        off = batches[-1].clock_offset
        for e in pipe.flush():
            e.t += off
            out.events.append(e)
    out.msdv = math.sqrt(pipe.dose)
    out.state = pipe.to_state()
    out.last_batch_seq = prev
    return out


# --- Segment passes -------------------------------------------------------------------------

@dataclass
class Pass:
    h3: str
    t_start: float
    duration_s: float
    mean_speed_ms: float | None
    roughness_rms: float | None
    aw_rms: float
    pothole_count: int
    n_windows: int
    # D45: sickness counts the moving, valid windows only (the ones roughness uses, whatever their number).
    sickness_s: float = 0.0
    sickness_aw_rms: float | None = None


def _haversine_m(lat1, lon1, lat2, lon2) -> np.ndarray:
    r = 6_371_008.8
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dp, dl = p2 - p1, np.radians(lon2 - lon1)
    a = np.sin(dp / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


def trip_distance_m(fixes: list[Fix]) -> float:
    """Length of the trip (m) from its fixes in time order (rule above DISTANCE_MAX_HACC_M)."""
    pts = [x for x in fixes if x.h_acc_m is not None and x.h_acc_m <= DISTANCE_MAX_HACC_M]
    if len(pts) < 2:
        return 0.0
    a = np.asarray([(x.lat, x.lon) for x in pts], dtype=float)
    steps = _haversine_m(a[:-1, 0], a[:-1, 1], a[1:, 0], a[1:, 1])
    total = 0.0
    for step, p, q in zip(steps, pts[:-1], pts[1:]):
        speeds = [v for v in (p.speed_ms, q.speed_ms) if v is not None]
        if not speeds or max(speeds) >= DISTANCE_MIN_SPEED_MS:
            total += float(step)
    return total


def build_passes(series: list[SeriesPoint], fixes: list[tuple[float, float, float]],
                 pothole_times: list[float], cell_of=None, invalid: np.ndarray | None = None) -> list[Pass]:
    """Splits the 5 Hz series into passes through H3 cells. A window's position is interpolated
    between the GPS fixes around it; a window without one ends the current pass. `invalid` windows
    (the phone was handled or had moved in its mount) don't count for roughness or sickness."""
    if cell_of is None:
        import h3

        def cell_of(lat, lon):
            return h3.latlng_to_cell(lat, lon, H3_RESOLUTION)

    if not series or not fixes:
        return []
    fa = np.asarray(fixes, dtype=float)
    ft = fa[:, 0]
    t = np.array([p.t for p in series])
    lat, lon = (np.interp(t, ft, col) for col in (fa[:, 1], fa[:, 2]))
    if len(ft) > 1:
        i = np.clip(np.searchsorted(ft, t), 1, len(ft) - 1)
        bracket = ft[i] - ft[i - 1]
    else:
        bracket = np.zeros_like(t)
    has_pos = (t >= ft[0] - FIX_EDGE_S) & (t <= ft[-1] + FIX_EDGE_S) & \
              ((t < ft[0]) | (t > ft[-1]) | (bracket <= MAX_FIX_GAP_S))
    potholes = np.sort(np.asarray(pothole_times, dtype=float))

    passes: list[Pass] = []
    run: list[int] = []
    run_cell = None

    def flush():
        if not run:
            return
        pts = [series[k] for k in run]
        moving = [series[k] for k in run if series[k].speed is not None and series[k].speed >= MOVING_SPEED_MS
                  and not (invalid is not None and invalid[k])]
        known = [p.speed for p in pts if p.speed is not None]
        if len(moving) >= MIN_MOVING_WINDOWS:
            rough = math.sqrt(sum(p.rough_rms ** 2 for p in moving) / len(moving))
            speed = sum(p.speed for p in moving) / len(moving)
        else:
            rough = None
            speed = sum(known) / len(known) if known else None
        duration = len(pts) * WINDOW_S
        sick_s = len(moving) * WINDOW_S
        t0, t1 = pts[0].t - WINDOW_S, pts[-1].t
        passes.append(Pass(
            h3=run_cell, t_start=t0, duration_s=duration, mean_speed_ms=speed, roughness_rms=rough,
            aw_rms=math.sqrt(sum(p.dose_inc for p in pts) / duration),
            pothole_count=int(np.count_nonzero((potholes > t0) & (potholes <= t1))),
            n_windows=len(pts), sickness_s=sick_s,
            sickness_aw_rms=math.sqrt(sum(p.dose_inc for p in moving) / sick_s) if moving else None))

    for k in range(len(series)):
        if not has_pos[k]:
            flush()
            run, run_cell = [], None
            continue
        cell = cell_of(float(lat[k]), float(lon[k]))
        if cell != run_cell:
            flush()
            run, run_cell = [], cell
        run.append(k)
    flush()
    return passes


# --- Quality (plan §9 step 3, §10) ----------------------------------------------------------

def stream_quality(times: list[float], expected_hz: float | None) -> dict:
    """API.md StreamQuality for one sensor stream; `times` in seconds, any clock."""
    if len(times) < 2:
        return {"rows": len(times), "rateHz": None, "expectedHz": expected_hz, "maxGapS": None, "gapsOver1s": 0}
    t = np.sort(np.asarray(times, dtype=float))
    gaps = np.diff(t)
    span = float(t[-1] - t[0])
    return {"rows": len(t), "rateHz": round((len(t) - 1) / span, 2) if span > 0 else None,
            "expectedHz": expected_hz, "maxGapS": round(float(gaps.max()), 3),
            "gapsOver1s": int(np.count_nonzero(gaps > 1.0))}


INVALID_DEGRADED_SHARE = 0.10  # PROVISIONAL: more of the trip than this handled / moved / mismatched


def assess(trip: Trip, sig: TripSignal, expected_batches: int | None,
           fixes: list[tuple[float, float, float, float | None]],
           invalid: dict[str, np.ndarray] | None = None) -> tuple[str, float | None, dict]:
    """Returns (quality_status, valid_fraction, quality json). `invalid` holds the per-window masks
    of quality.py (phone_moved, gravity_drift, gyro_gps_mismatch). PROVISIONAL rules:
    bad = no motion or no GPS, or under half the expected motion samples;
    degraded = missing batches, filter restarts, under 90 % of the motion samples, mostly poor GPS,
    or over 10 % of the trip invalid for one of the reasons above."""
    motion_t = [x for f in trip.batches for x in f.motion_t]
    motion = stream_quality(motion_t, MOTION_HZ)
    location = stream_quality([f[0] for f in fixes], 1.0)
    coverage = None
    if motion["rows"] >= 2:
        span = max(motion_t) - min(motion_t)
        coverage = min(1.0, motion["rows"] / (span * MOTION_HZ + 1)) if span > 0 else None
    h_acc = [f[3] for f in fixes if f[3] is not None]
    good_gps = sum(1 for h in h_acc if h <= GPS_GOOD_HACC_M) / len(h_acc) if h_acc else None
    seqs = {f.batch_seq for f in trip.batches}
    missing = max(0, expected_batches - len({s for s in seqs if s < expected_batches})) \
        if expected_batches is not None else None

    # Windows of the trip without a usable fix (no fix within 2 s, or only poor ones). A fix without an
    # accuracy (iOS reports -1) is unknown, not poor, as for good_gps.
    poor = np.zeros(len(sig.series), dtype=bool)
    if sig.series:
        ft = np.asarray([f[0] for f in fixes]) if fixes else np.zeros(0)
        acc = [f[3] for f in fixes]
        for i, p in enumerate(sig.series):
            j = int(np.searchsorted(ft, p.t)) if len(ft) else 0
            near = [k for k in (j - 1, j) if 0 <= k < len(ft) and abs(ft[k] - p.t) <= 2.0]
            known = [acc[k] for k in near if acc[k] is not None]
            poor[i] = not near or (bool(known) and min(known) > GPS_GOOD_HACC_M)
    masks = {k: np.zeros(len(sig.series), dtype=bool) for k in ("phone_moved", "gravity_drift", "gyro_gps_mismatch")}
    masks.update(invalid or {})
    trip_s = len(sig.series) * WINDOW_S
    # Plan §9 step 3: windows are invalid for phone_moved, gravity drift or a gyro/GPS mismatch. Poor GPS
    # is reported (gps_poor, and "mostly poor GPS" degrades the trip) but doesn't make the motion invalid.
    invalid_any = np.zeros(len(sig.series), dtype=bool)
    for m in masks.values():
        invalid_any |= m
    valid = None
    if coverage is not None and trip_s > 0:
        valid = round(max(0.0, coverage * (1.0 - float(invalid_any.sum()) * WINDOW_S / trip_s)), 4)
    worst_share = max(float(m.sum()) * WINDOW_S / trip_s for m in masks.values()) if trip_s > 0 else 0.0

    if not sig.series or not fixes or coverage is None or coverage < 0.5:
        status = "bad"
    elif (missing or 0) > 0 or sig.resets > 0 or coverage < 0.9 or (good_gps is not None and good_gps < 0.5) \
            or worst_share > INVALID_DEGRADED_SHARE:
        status = "degraded"
    else:
        status = "ok"
    quality = {
        "streams": {"deviceMotion": motion, **trip.streams, "location": location},
        "finalizedFrom": trip.origin,
        "validFraction": valid,
        "invalidSeconds": {**{k: round(float(m.sum()) * WINDOW_S, 1) for k, m in masks.items()},
                           "gps_poor": round(float(poor.sum()) * WINDOW_S, 1)},
        "missingBatches": missing,
        "filterRestarts": sig.resets,
        "motionCoverage": None if coverage is None else round(coverage, 4),
    }
    return status, valid, quality


@dataclass
class TripChecks:
    masks: dict[str, np.ndarray]  # per series window: phone_moved, gravity_drift, gyro_gps_mismatch
    taps: list[tuple[float, str]]  # every label as (epoch s, type), ascending

    def handled_at(self, t: float) -> bool:
        return bool(quality.handled(np.array([t]), self.taps)[0])


def trip_checks(trip: Trip, sig: TripSignal, fixes: list) -> TripChecks:
    """quality.py's whole-trip checks on the trip's samples, on UTC like the series."""
    t = np.concatenate([np.asarray(f.motion_t, dtype=float) + f.clock_offset for f in trip.batches]) \
        if trip.batches else np.zeros(0)

    def stack(attr: str) -> np.ndarray:
        parts = [np.asarray(getattr(f, attr), dtype=float).reshape(-1, 3) for f in trip.batches]
        return np.vstack(parts) if parts else np.zeros((0, 3))

    motion = quality.Motion(t=t, g=stack("motion_g"), rr=stack("motion_rr"))
    labels = sorted((lab.t.timestamp(), lab.type) for f in trip.batches for lab in f.labels)
    mids = quality.window_mids([p.t for p in sig.series], WINDOW_S)
    masks = {
        "phone_moved": quality.handled(mids, labels),
        "gravity_drift": quality.gravity_drift(mids, motion),
        "gyro_gps_mismatch": quality.gyro_gps_mismatch(
            mids, motion, [(x.t.timestamp(), x.speed_ms, x.course_deg) for x in fixes]),
    }
    return TripChecks(masks=masks, taps=labels)


# --- Parquet (plan §5 "Finalize job") ------------------------------------------------------

def _parquet(columns: dict[str, np.ndarray]) -> bytes:
    import pyarrow as pa
    import pyarrow.parquet as pq

    buf = io.BytesIO()
    pq.write_table(pa.table(columns), buf, compression="zstd")
    return buf.getvalue()


def _utc(seconds: np.ndarray) -> np.ndarray:
    return (np.asarray(seconds, dtype=float) * 1e6).round().astype("datetime64[us]")


def write_parquet(archive: Archive, trip: Trip, sig: TripSignal) -> list[str]:
    """The trip's samples and 5 Hz results under `processed/session=<id>/`, one file each, overwritten
    on a rerun. Raw values in the phone's units and frame (g, rad/s), UTC times; readable with
    pandas, or DuckDB over every trip (`read_parquet('processed/*/motion.parquet', hive_partitioning=1)`)."""
    def cat(attr: str, width: int | None = None) -> np.ndarray:
        parts = [np.asarray(getattr(f, attr), dtype=float) for f in trip.batches]
        parts = [x.reshape(-1, width) if width else x.reshape(-1) for x in parts]
        return np.concatenate(parts) if parts else np.zeros((0, width) if width else 0)

    t_up = cat("motion_t")
    t_utc = np.concatenate([np.asarray(f.motion_t, dtype=float) + f.clock_offset for f in trip.batches])
    ua, g, rr = cat("motion_ua", 3), cat("motion_g", 3), cat("motion_rr", 3)
    motion = {"t_utc": _utc(t_utc), "t_up": t_up}
    for name, arr in (("ua", ua), ("g", g), ("rr", rr)):
        for i, axis in enumerate("xyz"):
            motion[f"{name}_{axis}"] = arr[:, i]
    fixes = sorted({x.t.timestamp(): x for f in trip.batches for x in f.fixes}.items())
    location = {
        "t_utc": _utc(np.array([t for t, _ in fixes])),
        "lat": np.array([x.lat for _, x in fixes], dtype=float),
        "lon": np.array([x.lon for _, x in fixes], dtype=float),
        **{col: np.array([np.nan if getattr(x, attr) is None else getattr(x, attr) for _, x in fixes], dtype=float)
           for col, attr in (("speed_ms", "speed_ms"), ("course_deg", "course_deg"), ("h_acc_m", "h_acc_m"))},
    }
    series = {
        "t_utc": _utc(np.array([p.t for p in sig.series])),
        **{col: np.array([np.nan if getattr(p, col) is None else getattr(p, col) for p in sig.series], dtype=float)
           for col in ("a_vert", "a_lat", "a_lon", "speed", "msdv", "rough_rms", "dose_inc")},
    }
    names = []
    for name, cols in (("motion", motion), ("location", location), ("series", series)):
        blob = f"processed/session={trip.session_id}/{name}.parquet"
        archive.write(blob, _parquet(cols))
        names.append(blob)
    return names


# --- Writing --------------------------------------------------------------------------------

def pick_trip(archive: Archive, uploads: upload.Uploads | None, session_id: str, *,
              require_upload: bool = False) -> Trip:
    """The uploaded folder if there is a complete one, else the live archive. Raises
    upload.UploadInvalid only when `require_upload` (a message for that upload)."""
    if uploads is not None and (require_upload or upload.has_upload(uploads, session_id)):
        try:
            return from_upload(upload.load(uploads, session_id))
        except upload.UploadInvalid as e:
            if require_upload:
                raise
            log.warning("upload of %s can't be used (%s); finalizing from the live archive", session_id, e)
    return load_trip(archive, session_id)


def finalize_session(conn: Connection, archive: Archive, session_id: str,
                     uploads: upload.Uploads | None = None, *, require_upload: bool = False) -> dict | None:
    """Finalizes one trip; returns a short summary, or None if there's nothing to finalize it from."""
    trip = pick_trip(archive, uploads, session_id, require_upload=require_upload)
    if not trip.batches:
        return None
    sig = run_pipeline(trip.batches)
    by_time = {x.t.timestamp(): x for f in trip.batches for x in f.fixes}
    fix_objs = [by_time[k] for k in sorted(by_time)]
    fixes = [(x.t.timestamp(), x.lat, x.lon, x.h_acc_m) for x in fix_objs]
    checks = trip_checks(trip, sig, fix_objs)
    events = [e for e in sig.events if not checks.handled_at(e.t)]  # the phone being handled, not the road
    detection, matched = quality.score_detections([(e.t, e.type) for e in events], checks.taps)
    # A secondary output: a failed write must not keep the trip from being finalized (5 failures would
    # dead-letter it). It's logged and recorded in quality.parquetError; the next finalize writes it.
    try:
        parquet, parquet_error = write_parquet(archive, trip, sig), None
    except Exception as e:  # noqa: BLE001
        log.exception("Parquet output of %s failed; finalizing without it", session_id)
        parquet, parquet_error = [], f"{type(e).__name__}: {e}"[:500]
    store = Store(conn)

    with conn.transaction():
        first = trip.batches[0]
        store._touch_device(first.device_id)
        # A trip that also streamed keeps its source ('live'); one that only came by upload is 'upload'.
        conn.execute(
            "INSERT INTO sessions (session_id, device_id, source, started_at) VALUES (%s, %s, %s, %s) "
            "ON CONFLICT (session_id) DO NOTHING",
            (session_id, first.device_id, trip.source or first.source, first.t0_utc),
        )
        for m in trip.meta:  # in case a copy never reached the stream processor
            store.apply_session(parse_session(m))
        if trip.origin == "upload":
            # The folder has every fix and tap. Its label times come from the CSV, which can differ by a
            # millisecond from the live batch's, so the live rows go rather than appear twice.
            for table in ("track_points", "labels"):
                conn.execute(f"DELETE FROM {table} WHERE session_id = %s", (session_id,))

        with conn.cursor() as cur:
            cur.executemany(
                """
                INSERT INTO track_points (session_id, t, geom, speed_ms, course_deg, h_acc_m)
                VALUES (%s, %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s, %s, %s)
                ON CONFLICT (session_id, t) DO NOTHING
                """,
                [(session_id, x.t, x.lon, x.lat, x.speed_ms, x.course_deg, x.h_acc_m)
                 for f in trip.batches for x in f.fixes],
            )
            cur.executemany(
                "INSERT INTO labels (session_id, t, type, value, note) VALUES (%s, %s, %s, %s, %s) "
                "ON CONFLICT (session_id, t, type) DO NOTHING",
                [(session_id, lab.t, lab.type, lab.value, lab.note) for f in trip.batches for lab in f.labels],
            )

            for table in ("session_series", "events", "segment_observations"):
                conn.execute(f"DELETE FROM {table} WHERE session_id = %s", (session_id,))
            # Keep the trip's pipeline state, now the one-pass result: a backlog batch that reopens
            # the trip continues the dose instead of restarting it at 0.
            if sig.last_batch_seq is not None:
                conn.execute(
                    """
                    INSERT INTO signal_state (session_id, state, last_batch_seq, gaps, updated_at)
                    VALUES (%s, %s, %s, %s, now())
                    ON CONFLICT (session_id) DO UPDATE SET
                      state = EXCLUDED.state, last_batch_seq = EXCLUDED.last_batch_seq,
                      gaps = EXCLUDED.gaps, updated_at = now()
                    """,
                    (session_id, Jsonb(sig.state), sig.last_batch_seq, sig.resets),
                )
            cur.executemany(
                "INSERT INTO session_series (session_id, t, a_vert, a_lat, a_lon, speed_ms, msdv) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT (session_id, t) DO NOTHING",
                [(session_id, from_epoch(p.t), p.a_vert, p.a_lat, p.a_lon, p.speed, p.msdv)
                 for p in sig.series],
            )
            cur.executemany(
                """
                INSERT INTO events (session_id, type, t, geom, speed_ms, magnitude, confidence, matched_label)
                VALUES (%s, %s, %s,
                        (SELECT geom FROM track_points WHERE session_id = %s
                         ORDER BY abs(extract(epoch FROM t - %s)) LIMIT 1),
                        %s, %s, %s, %s)
                ON CONFLICT (session_id, type, t) DO NOTHING
                """,
                [(session_id, e.type, from_epoch(e.t), session_id, from_epoch(e.t), e.speed, e.magnitude,
                  e.confidence, m) for e, m in zip(events, matched)],
            )
            passes = build_passes(sig.series, [f[:3] for f in fixes],
                                  [e.t for e in events if e.type == "pothole"],
                                  invalid=checks.masks["phone_moved"] | checks.masks["gravity_drift"])
            cur.executemany(
                """
                INSERT INTO segment_observations (session_id, pass_idx, h3, t_start, duration_s,
                  mean_speed_ms, roughness_rms, aw_rms, pothole_count, n_windows, sickness_s, sickness_aw_rms)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                [(session_id, i, p.h3, from_epoch(p.t_start), p.duration_s, p.mean_speed_ms,
                  p.roughness_rms, p.aw_rms, p.pothole_count, p.n_windows, p.sickness_s, p.sickness_aw_rms)
                 for i, p in enumerate(passes)],
            )

        # An upload's batches are rebuilt windows, not the phone's numbering: no batch count applies.
        expected = None if trip.origin == "upload" else conn.execute(
            "SELECT expected_batch_count FROM sessions WHERE session_id = %s", (session_id,)).fetchone()[0]
        status, valid, q = assess(trip, sig, expected, fixes, checks.masks)
        q["detection"] = detection
        q["parquet"] = parquet
        if parquet_error:
            q["parquetError"] = parquet_error
        missing = q["missingBatches"]
        incomplete = trip.incomplete if trip.incomplete is not None else expected is None or (missing or 0) > 0
        last_t = sig.series[-1].t if sig.series else trip.batches[-1].end_utc.timestamp()
        conn.execute(
            """
            UPDATE sessions SET status = 'complete', incomplete = %s, msdv_z = %s, quality_status = %s,
              valid_fraction = %s, quality = %s, distance_m = %s, finalized_at = now(),
              ended_at = COALESCE(ended_at, %s), updated_at = now()
            WHERE session_id = %s
            """,
            (incomplete, sig.msdv, status, valid, Jsonb(q),
             trip_distance_m(fix_objs), from_epoch(last_t),
             session_id),
        )
        store._refresh_exclusions(session_id)

    summary = {"batches": len(trip.batches), "series": len(sig.series), "events": len(events),
               "passes": len(passes), "msdv": round(sig.msdv, 4), "quality": status, "from": trip.origin}
    log.info("finalized %s %s", session_id, " ".join(f"{k}={v}" for k, v in summary.items()))
    return summary


# --- Queue messages -------------------------------------------------------------------------

def parse_message(body: bytes) -> tuple[str, str | None]:
    """("live", id) from the stream processor, ("upload", id) from Event Grid, ("invalid", None)."""
    try:
        doc = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return "invalid", None
    if isinstance(doc, list) and len(doc) == 1:
        doc = doc[0]
    if not isinstance(doc, dict):
        return "invalid", None
    sid = doc.get("sessionId")
    if isinstance(sid, str) and sid:
        return "live", sid
    m = _SUBJECT_RE.search(str(doc.get("subject", "")))
    if m:
        return "upload", m.group(1)
    return "invalid", None


def park(conn: Connection, session_id: str) -> None:
    """A trip whose message is dead-lettered stays `processing` but isn't resent by ready.py
    (`ready_sent_at = infinity`) until new data reopens it or someone fixes it by hand."""
    with conn.transaction():
        conn.execute("UPDATE sessions SET ready_sent_at = 'infinity' WHERE session_id = %s AND status = 'processing'",
                     (session_id,))


def handle(conn: Connection, archive: Archive, body: bytes,
           uploads: upload.Uploads | None = None) -> tuple[str, str]:
    """Returns ("complete" | "dead_letter", reason). Raises on a failure worth retrying."""
    kind, sid = parse_message(body)
    if kind == "invalid":
        return "dead_letter", "unreadable message"
    if kind == "upload":
        if uploads is None:
            return "dead_letter", f"no sessions container configured (upload of {sid})"
        try:
            summary = finalize_session(conn, archive, sid, uploads, require_upload=True)
        except upload.UploadInvalid as e:
            return "dead_letter", f"upload of {sid} can't be used: {e}"
        if summary is None:
            return "dead_letter", f"upload of {sid} has no samples"
    else:
        summary = finalize_session(conn, archive, sid, uploads)
        if summary is None:
            park(conn, sid)
            return "dead_letter", f"no raw archive for session {sid}"
    aggregate.rebuild(conn)
    return "complete", sid


def run() -> None:
    from azure.identity import DefaultAzureCredential
    from azure.servicebus import AutoLockRenewer, ServiceBusClient

    from .db import connect

    archive: Archive = DirArchive(os.environ["ARCHIVE_DIR"]) if os.environ.get("ARCHIVE_DIR") else \
        BlobArchive(os.environ["STORAGE_BLOB_ENDPOINT"], os.environ.get("LAKE_CONTAINER", "lake"))
    uploads: upload.Uploads = upload.DirUploads(os.environ["UPLOAD_DIR"]) if os.environ.get("UPLOAD_DIR") else \
        upload.BlobUploads(os.environ["STORAGE_BLOB_ENDPOINT"], os.environ.get("SESSIONS_CONTAINER", "sessions"))
    started = time.monotonic()
    failures = 0
    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    with ServiceBusClient(os.environ["SERVICEBUS_FULLY_QUALIFIED_NAMESPACE"], credential) as client, \
            client.get_queue_receiver(os.environ["SERVICEBUS_QUEUE_NAME"]) as receiver, \
            AutoLockRenewer(max_lock_renewal_duration=TIME_BUDGET_S + 600) as renewer, \
            connect(application_name="roadride-finalize") as conn:
        for _ in range(MAX_MESSAGES_PER_RUN):
            if time.monotonic() - started > TIME_BUDGET_S:
                break
            msgs = receiver.receive_messages(max_message_count=1, max_wait_time=10)
            if not msgs:
                break
            msg = msgs[0]
            renewer.register(receiver, msg)
            body = b"".join(bytes(part) for part in msg.body)
            try:
                outcome, reason = handle(conn, archive, body, uploads)
            except Exception:  # noqa: BLE001 - back to the queue; dead-lettered after 5 tries
                log.exception("finalize failed (delivery %d); abandoning the message", msg.delivery_count or 0)
                failures += 1
                if conn.broken or conn.closed:
                    receiver.abandon_message(msg)
                    break
                conn.rollback()
                kind, sid = parse_message(body)
                if kind == "live" and (msg.delivery_count or 0) >= MAX_DELIVERIES:
                    park(conn, sid)  # Service Bus dead-letters it after this try: stop resending
                receiver.abandon_message(msg)
                continue
            if outcome == "complete":
                receiver.complete_message(msg)
            else:
                log.warning("dead-lettering message: %s", reason)
                receiver.dead_letter_message(msg, reason="finalize", error_description=reason[:1000])
    if failures:
        raise SystemExit(1)
