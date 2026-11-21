"""The finalize job (plan §5 "Finalize job", §7 "When the trip ends").

Started by KEDA when "session ready" lands in the Service Bus queue. For each message it:
1. reads the trip's whole raw archive from the `lake` container (`raw/session=<id>/`: every batch
   the ingest function accepted, plus the Start and Stop copies of session.json);
2. runs the same signal pipeline as the stream processor over the complete trip in one pass, batch
   by batch in sequence order, so late batches count too and the filters restart only at real holes;
3. replaces the trip's live results (series, events) and writes one segment observation per H3
   cell pass, the trip's quality measurements and status `complete`, in one transaction;
4. rebuilds the aggregates (aggregate.rebuild), then completes the message.

Everything it writes is deleted and rewritten per trip, so a redelivered or resent message is
harmless. Messages from Event Grid (a laptop upload's `_complete.json`) are dead-lettered for now:
reading the uploaded CSV folder isn't built yet, and a dead letter keeps the message for later.

Thresholds in the quality checks are PROVISIONAL, like the pothole threshold in dsp.py.
"""

from __future__ import annotations

import gzip
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

from . import aggregate
from .dsp import Event, Pipeline, SeriesPoint
from .live import BatchFacts, parse_batch, parse_session
from .store import Store, from_epoch

log = logging.getLogger(__name__)

H3_RESOLUTION = aggregate.H3_RESOLUTION
WINDOW_S = 0.2  # session_series spacing (dsp.SERIES_EVERY at 100 Hz)
MOVING_SPEED_MS = 1.0  # windows slower than this don't count for a pass's roughness (as the mock)
MIN_MOVING_WINDOWS = 3
PRIVACY_TRIM_M = 200.0  # plan §11: same as the read API
MAX_FIX_GAP_S = 10.0  # no position between two fixes further apart than this
FIX_EDGE_S = 2.0  # a window this close before the first / after the last fix still gets a position
MOTION_HZ = 100.0
GPS_GOOD_HACC_M = 20.0  # PROVISIONAL: a fix worse than this counts as poor GPS

MAX_MESSAGES_PER_RUN = 20  # KEDA starts one execution per message; draining a few more is cheaper
TIME_BUDGET_S = 20 * 60  # stop taking new messages well before the job's 30-minute limit
DOWNLOAD_THREADS = 16
MAX_DELIVERIES = 5  # the queue's max_delivery_count (infra/modules/messaging)

_SUBJECT_RE = re.compile(r"/containers/[^/]+/blobs/([^/]+)/_complete\.json$")


# --- The raw archive ------------------------------------------------------------------------

class Archive(Protocol):
    def list_names(self, session_id: str) -> list[str]: ...
    def read(self, name: str) -> bytes: ...


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
        return self._client.download_blob(name).readall()


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


@dataclass
class Trip:
    session_id: str
    batches: list[BatchFacts]  # unique batch_seq, ascending
    meta: list[dict]  # session.json copies: Start first, then Stop


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


def run_pipeline(batches: list[BatchFacts]) -> TripSignal:
    """The stream processor's per-batch steps (store.Store._process_signal), without the database:
    the same pipeline, batch by batch, reset at a missing batch, results moved to UTC with each
    batch's own clock offset. A cleanly streamed trip gives the live numbers again."""
    pipe = Pipeline()
    out = TripSignal()
    prev = None
    for f in batches:
        off = f.clock_offset
        res = pipe.feed(
            np.asarray(f.motion_t, dtype=float),
            np.asarray(f.motion_ua, dtype=float).reshape(-1, 3),
            np.asarray(f.motion_g, dtype=float).reshape(-1, 3),
            [(x.t.timestamp() - off, x.speed_ms) for x in f.fixes],
            reset=prev is not None and f.batch_seq != prev + 1,
        )
        for p in res.series:
            p.t += off
        for e in res.events:
            e.t += off
        out.series += res.series
        out.events += res.events
        out.resets += int(res.reset)
        prev = f.batch_seq
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
    in_privacy_zone: bool


def _haversine_m(lat1, lon1, lat2, lon2) -> np.ndarray:
    r = 6_371_008.8
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dp, dl = p2 - p1, np.radians(lon2 - lon1)
    a = np.sin(dp / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


def track_distance(fixes: list[tuple[float, float, float]]) -> np.ndarray:
    """Cumulative distance (m) at each fix; fixes are (epoch s, lat, lon), ascending."""
    if not fixes:
        return np.zeros(0)
    a = np.asarray(fixes, dtype=float)
    steps = _haversine_m(a[:-1, 1], a[:-1, 2], a[1:, 1], a[1:, 2]) if len(a) > 1 else np.zeros(0)
    return np.concatenate([[0.0], np.cumsum(steps)])


def build_passes(series: list[SeriesPoint], fixes: list[tuple[float, float, float]],
                 pothole_times: list[float], cell_of=None) -> list[Pass]:
    """Splits the 5 Hz series into passes through H3 cells. A window's position is interpolated
    between the GPS fixes around it; a window without one ends the current pass."""
    if cell_of is None:
        import h3

        def cell_of(lat, lon):
            return h3.latlng_to_cell(lat, lon, H3_RESOLUTION)

    if not series or not fixes:
        return []
    fa = np.asarray(fixes, dtype=float)
    ft, dist = fa[:, 0], track_distance(fixes)
    total = float(dist[-1])
    t = np.array([p.t for p in series])
    lat, lon, d = (np.interp(t, ft, col) for col in (fa[:, 1], fa[:, 2], dist))
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
        moving = [p for p in pts if p.speed is not None and p.speed >= MOVING_SPEED_MS]
        known = [p.speed for p in pts if p.speed is not None]
        if len(moving) >= MIN_MOVING_WINDOWS:
            rough = math.sqrt(sum(p.rough_rms ** 2 for p in moving) / len(moving))
            speed = sum(p.speed for p in moving) / len(moving)
        else:
            rough = None
            speed = sum(known) / len(known) if known else None
        duration = len(pts) * WINDOW_S
        t0, t1 = pts[0].t - WINDOW_S, pts[-1].t
        mid = float(d[run[len(run) // 2]])
        passes.append(Pass(
            h3=run_cell, t_start=t0, duration_s=duration, mean_speed_ms=speed, roughness_rms=rough,
            aw_rms=math.sqrt(sum(p.dose_inc for p in pts) / duration),
            pothole_count=int(np.count_nonzero((potholes > t0) & (potholes <= t1))),
            n_windows=len(pts), in_privacy_zone=mid < PRIVACY_TRIM_M or mid > total - PRIVACY_TRIM_M))

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


def assess(trip: Trip, sig: TripSignal, expected_batches: int | None,
           fixes: list[tuple[float, float, float, float | None]]) -> tuple[str, float | None, dict]:
    """Returns (quality_status, valid_fraction, quality json). PROVISIONAL rules:
    bad = no motion or no GPS, or under half the expected motion samples;
    degraded = missing batches, filter restarts, under 90 % of the motion samples or mostly poor GPS."""
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

    # Seconds of the trip without a usable fix (no fix within the window, or a poor one).
    poor_s = 0.0
    if sig.series:
        ft = np.asarray([f[0] for f in fixes]) if fixes else np.zeros(0)
        acc = np.asarray([f[3] if f[3] is not None else np.inf for f in fixes]) if fixes else np.zeros(0)
        for p in sig.series:
            j = int(np.searchsorted(ft, p.t)) if len(ft) else 0
            near = [k for k in (j - 1, j) if 0 <= k < len(ft) and abs(ft[k] - p.t) <= 2.0]
            if not near or min(acc[k] for k in near) > GPS_GOOD_HACC_M:
                poor_s += WINDOW_S
    trip_s = len(sig.series) * WINDOW_S
    valid = None
    if coverage is not None and trip_s > 0:
        valid = round(max(0.0, coverage * (1.0 - poor_s / trip_s)), 4)

    if not sig.series or not fixes or coverage is None or coverage < 0.5:
        status = "bad"
    elif (missing or 0) > 0 or sig.resets > 0 or coverage < 0.9 or (good_gps is not None and good_gps < 0.5):
        status = "degraded"
    else:
        status = "ok"
    quality = {
        "streams": {"deviceMotion": motion, "location": location},
        "validFraction": valid,
        "invalidSeconds": {"phone_moved": 0, "gravity_drift": 0, "gyro_gps_mismatch": 0,
                           "gps_poor": round(poor_s, 1)},
        "missingBatches": missing,
        "filterRestarts": sig.resets,
        "motionCoverage": None if coverage is None else round(coverage, 4),
    }
    return status, valid, quality


# --- Writing --------------------------------------------------------------------------------

def finalize_session(conn: Connection, archive: Archive, session_id: str) -> dict | None:
    """Finalizes one trip; returns a short summary, or None if the archive has nothing for it."""
    trip = load_trip(archive, session_id)
    if not trip.batches:
        return None
    sig = run_pipeline(trip.batches)
    by_time = {x.t.timestamp(): (x.t.timestamp(), x.lat, x.lon, x.h_acc_m) for f in trip.batches for x in f.fixes}
    fixes = [by_time[k] for k in sorted(by_time)]
    store = Store(conn)

    with conn.transaction():
        first = trip.batches[0]
        store._touch_device(first.device_id)
        conn.execute(
            "INSERT INTO sessions (session_id, device_id, source, started_at) VALUES (%s, %s, %s, %s) "
            "ON CONFLICT (session_id) DO NOTHING",
            (session_id, first.device_id, first.source, first.t0_utc),
        )
        for m in trip.meta:  # in case a copy never reached the stream processor
            store.apply_session(parse_session(m))

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
                INSERT INTO events (session_id, type, t, geom, speed_ms, magnitude, confidence)
                VALUES (%s, %s, %s,
                        (SELECT geom FROM track_points WHERE session_id = %s
                         ORDER BY abs(extract(epoch FROM t - %s)) LIMIT 1),
                        %s, %s, %s)
                ON CONFLICT (session_id, type, t) DO NOTHING
                """,
                [(session_id, e.type, from_epoch(e.t), session_id, from_epoch(e.t), e.speed, e.magnitude,
                  e.confidence) for e in sig.events],
            )
            passes = build_passes(sig.series, [f[:3] for f in fixes],
                                  [e.t for e in sig.events if e.type == "pothole"])
            cur.executemany(
                """
                INSERT INTO segment_observations (session_id, pass_idx, h3, t_start, duration_s,
                  mean_speed_ms, roughness_rms, aw_rms, pothole_count, n_windows, in_privacy_zone)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                [(session_id, i, p.h3, from_epoch(p.t_start), p.duration_s, p.mean_speed_ms,
                  p.roughness_rms, p.aw_rms, p.pothole_count, p.n_windows, p.in_privacy_zone)
                 for i, p in enumerate(passes)],
            )

        expected = conn.execute("SELECT expected_batch_count FROM sessions WHERE session_id = %s",
                                (session_id,)).fetchone()[0]
        status, valid, quality = assess(trip, sig, expected, fixes)
        missing = quality["missingBatches"]
        last_t = sig.series[-1].t if sig.series else trip.batches[-1].end_utc.timestamp()
        conn.execute(
            """
            UPDATE sessions SET status = 'complete', incomplete = %s, msdv_z = %s, quality_status = %s,
              valid_fraction = %s, quality = %s, distance_m = %s, finalized_at = now(),
              ended_at = COALESCE(ended_at, %s), updated_at = now()
            WHERE session_id = %s
            """,
            (expected is None or (missing or 0) > 0, sig.msdv, status, valid, Jsonb(quality),
             float(track_distance([f[:3] for f in fixes])[-1]) if fixes else 0.0, from_epoch(last_t),
             session_id),
        )
        store._refresh_exclusions(session_id)

    summary = {"batches": len(trip.batches), "series": len(sig.series), "events": len(sig.events),
               "passes": len(passes), "msdv": round(sig.msdv, 4), "quality": status}
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


def handle(conn: Connection, archive: Archive, body: bytes) -> tuple[str, str]:
    """Returns ("complete" | "dead_letter", reason). Raises on a failure worth retrying."""
    kind, sid = parse_message(body)
    if kind == "invalid":
        return "dead_letter", "unreadable message"
    if kind == "upload":
        return "dead_letter", f"upload finalize not built yet (session {sid})"
    summary = finalize_session(conn, archive, sid)
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
                outcome, reason = handle(conn, archive, body)
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
