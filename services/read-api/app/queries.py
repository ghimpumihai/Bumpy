"""SQL and row → JSON for every route of dashboard/API.md.

Tables that the processing step will add (segments, events, session_series, segment_agg) don't exist
yet, so those routes answer with valid, empty shapes. Field names, defaults and rules follow the
dashboard's types (src/types/) and its mock backend (src/mock/), which is the working spec.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .fmt import epoch_ms, iso, rnd

if TYPE_CHECKING:  # only for type hints; keeps the pure helpers importable without a driver
    from psycopg import Connection

PRIVACY_TRIM_M = 200.0  # plan §11: first and last 200 m of every track stay private
LIVE_WINDOW_S = 60  # devices heard from in the last minute
LIVE_TRACK_S = 120  # last ~2 minutes of track on the live view
REF_SPEED_KMH = 36.0

SOURCES = ("upload", "live", "replay")
VEHICLE_TYPES = ("car", "bus", "tram", "bike", "boat", "unknown")
VEHICLE_FILTERS = ("all", "car", "bus", "tram")
EVENT_TYPES = ("pothole", "speed_bump", "rail_joint")

MOUNT_DEFAULTS = {"location": "", "phoneOrientation": "", "rigid": False, "handheld": False}
PEOPLE_DEFAULTS = {"operatorSeat": "", "raterSeat": "", "raterPosture": "seated", "passengerCount": 0}
SICKNESS_LABEL = "sickness"


class NotFound(Exception):
    pass


class BadRequest(Exception):
    pass


def enum_param(value: str | None, name: str, allowed: tuple[str, ...]) -> str | None:
    if value is None or value == "":
        return None
    if value not in allowed:
        raise BadRequest(f"{name} must be one of {', '.join(allowed)}")
    return value


def empty_feature_collection() -> dict:
    return {"type": "FeatureCollection", "features": []}


# --- Tracks and privacy ------------------------------------------------------------------

@dataclass
class TrackPoint:
    lon: float
    lat: float
    t: dt.datetime
    speed_ms: float | None
    s: float  # metres travelled since the first fix


TRACK_SQL = """
WITH pts AS (
  SELECT t, geom, speed_ms,
         ST_Distance(geom, lag(geom) OVER (ORDER BY t)) AS step
  FROM track_points WHERE session_id = %s
)
SELECT ST_X(geom::geometry), ST_Y(geom::geometry), t, speed_ms,
       COALESCE(sum(step) OVER (ORDER BY t), 0)
FROM pts ORDER BY t
"""


def track_points(conn: Connection, session_id: str) -> list[TrackPoint]:
    return [TrackPoint(lon, lat, t, speed, float(s))
            for lon, lat, t, speed, s in conn.execute(TRACK_SQL, (session_id,)).fetchall()]


def public_points(points: list[TrackPoint], ended: bool) -> list[TrackPoint]:
    """Drops the first 200 m, and the last 200 m once the trip has ended (plan §11)."""
    if not points:
        return []
    total = points[-1].s
    return [p for p in points
            if p.s >= PRIVACY_TRIM_M and (not ended or p.s <= total - PRIVACY_TRIM_M)]


# --- Sessions ----------------------------------------------------------------------------

SESSION_SQL = """
SELECT s.session_id, s.source, s.replay_of, s.device_id, s.status, s.incomplete, s.quality_status,
       s.include_in_agg, s.exclusion_reasons, s.context_known, s.vehicle_type, s.vehicle_make_model,
       s.vehicle_line, s.mount, s.people, s.audio_enabled, s.synthetic_sensors,
       COALESCE(s.started_at, s.created_at) AS started_at, s.ended_at,
       s.late_batches, s.duplicate_batches,
       (SELECT max(b.end_utc) FROM ingest_batches b WHERE b.session_id = s.session_id) AS last_sample_at,
       COALESCE((SELECT ST_Length(ST_MakeLine(tp.geom::geometry ORDER BY tp.t)::geography)
                 FROM track_points tp WHERE tp.session_id = s.session_id), 0) AS distance_m,
       (SELECT count(*) FROM labels l WHERE l.session_id = s.session_id AND l.type = %s) AS ratings
FROM sessions s
"""


def _merge(defaults: dict, stored) -> dict:
    out = dict(defaults)
    if isinstance(stored, dict):
        out.update({k: stored[k] for k in defaults if k in stored and stored[k] is not None})
    return out


def _summary(r: dict) -> dict:
    mount = _merge(MOUNT_DEFAULTS, r["mount"])
    roughness_eligible = bool(r["context_known"]) and mount["rigid"] is True and mount["handheld"] is not True
    end = r["ended_at"] or r["last_sample_at"] or r["started_at"]
    return {
        "sessionId": r["session_id"],
        "source": r["source"],
        "isMock": bool(r["synthetic_sensors"]),
        "replayOf": r["replay_of"],
        "deviceId": r["device_id"],
        "vehicle": {"type": r["vehicle_type"] or "unknown", "makeModel": r["vehicle_make_model"] or "",
                    "line": r["vehicle_line"]},
        "mount": mount,
        "people": _merge(PEOPLE_DEFAULTS, r["people"]),
        "audioEnabled": bool(r["audio_enabled"]),
        "startedAt": iso(r["started_at"]),
        "endedAt": iso(r["ended_at"]),
        "durationS": max(0.0, round((end - r["started_at"]).total_seconds(), 3)),
        "distanceM": round(float(r["distance_m"]), 1),
        "status": r["status"],
        "incomplete": bool(r["incomplete"]),
        "qualityStatus": r["quality_status"],
        "validFraction": None,  # comes with the quality checks (plan §9 step 3)
        "includeInAgg": bool(r["include_in_agg"]),
        "exclusionReasons": list(r["exclusion_reasons"] or []),
        "roughnessEligible": roughness_eligible,
        "sicknessExperimental": not roughness_eligible,
        "msdvZ": None,  # comes with the signal processing
        "msiPct": None,
        "eventCounts": {"pothole": 0, "speed_bump": 0, "rail_joint": 0},
        "ratingsCount": int(r["ratings"]),
    }


def _rows(conn: Connection, sql: str, args: tuple) -> list[dict]:
    cur = conn.execute(sql, args)
    cols = [c.name for c in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def _session_row(conn: Connection, session_id: str) -> dict:
    rows = _rows(conn, SESSION_SQL + " WHERE s.session_id = %s", (SICKNESS_LABEL, session_id))
    if not rows:
        raise NotFound(f"session {session_id} not found")
    return rows[0]


def _quality(conn: Connection, r: dict) -> dict:
    fixes, median, p95 = conn.execute(
        """
        SELECT count(*),
               percentile_cont(0.5) WITHIN GROUP (ORDER BY h_acc_m),
               percentile_cont(0.95) WITHIN GROUP (ORDER BY h_acc_m)
        FROM track_points WHERE session_id = %s
        """,
        (r["session_id"],),
    ).fetchone()
    return {
        "streams": {},  # per-stream rates come with the finalize job (it has the full trip)
        "gps": {"fixes": int(fixes), "medianHAccM": rnd(median, 2), "p95HAccM": rnd(p95, 2)},
        "validFraction": None,
        "invalidSeconds": {"phone_moved": 0, "gravity_drift": 0, "gyro_gps_mismatch": 0, "gps_poor": 0},
        "rejectedBatches": 0,  # rejected batches never reach the database (the ingest function answers 4xx)
        "lateBatches": int(r["late_batches"]),
        "duplicateBatches": int(r["duplicate_batches"]),
    }


def _ratings(conn: Connection, session_id: str) -> list[dict]:
    out = []
    for t, value in conn.execute(
            "SELECT t, value FROM labels WHERE session_id = %s AND type = %s ORDER BY t",
            (session_id, SICKNESS_LABEL)).fetchall():
        try:
            out.append({"tUtc": iso(t), "value": int(float(value)), "msdvSoFar": None})
        except (TypeError, ValueError):
            continue  # a rating without a number (skipped prompt) isn't a rating
    return out


def session_list(conn: Connection, source: str | None, vehicle: str | None) -> dict:
    sql = SESSION_SQL + " WHERE (%s::text IS NULL OR s.source = %s) AND (%s::text IS NULL OR s.vehicle_type = %s)" \
                        " ORDER BY COALESCE(s.started_at, s.created_at) DESC"
    rows = _rows(conn, sql, (SICKNESS_LABEL, source, source, vehicle, vehicle))
    return {"sessions": [_summary(r) for r in rows]}


def session_detail(conn: Connection, session_id: str) -> dict:
    r = _session_row(conn, session_id)
    return {
        **_summary(r),
        "quality": _quality(conn, r),
        "detection": None,
        "sickness": {"msdvZ": None, "msiPct": None, "ratings": _ratings(conn, session_id), "spearman": None},
        "processedAt": None,
        "processorVersion": None,
    }


def quality_list(conn: Connection) -> dict:
    rows = _rows(conn, SESSION_SQL + " ORDER BY COALESCE(s.started_at, s.created_at) DESC", (SICKNESS_LABEL,))
    return {"sessions": [{**_summary(r), "quality": _quality(conn, r)} for r in rows]}


def session_track(conn: Connection, session_id: str) -> dict:
    r = _session_row(conn, session_id)
    pts = public_points(track_points(conn, session_id), ended=r["status"] != "live")
    return {
        "type": "Feature",
        "geometry": {"type": "LineString", "coordinates": [[rnd(p.lon), rnd(p.lat)] for p in pts]},
        "properties": {
            "sessionId": session_id,
            "times": [epoch_ms(p.t) for p in pts],
            "speeds": [rnd(p.speed_ms, 2) for p in pts],
            "trimmedM": PRIVACY_TRIM_M,
        },
    }


def session_labels(conn: Connection, session_id: str) -> dict:
    _session_row(conn, session_id)
    rows = conn.execute("SELECT t, type, value, note FROM labels WHERE session_id = %s ORDER BY t",
                        (session_id,)).fetchall()
    return {"labels": [{"tUtc": iso(t), "type": ty, "value": v, "note": n} for t, ty, v, n in rows]}


def session_series(conn: Connection, session_id: str) -> dict:
    _session_row(conn, session_id)
    return {"t": [], "aVert": [], "aLat": [], "aLon": [], "speed": [], "msdv": []}


def session_events(conn: Connection, session_id: str) -> dict:
    _session_row(conn, session_id)
    return empty_feature_collection()


# --- Live ---------------------------------------------------------------------------------

def live(conn: Connection, now: dt.datetime) -> dict:
    rows = _rows(conn, """
        SELECT ls.*, s.source, s.status, s.vehicle_type
        FROM live_state ls JOIN sessions s USING (session_id)
        WHERE ls.received_at > %s AND ls.lat IS NOT NULL
        ORDER BY ls.device_id
        """, (now - dt.timedelta(seconds=LIVE_WINDOW_S),))
    devices = []
    for r in rows:
        ended = r["status"] != "live"
        if ended:
            continue  # its current position is its endpoint, inside the private last 200 m
        pts = track_points(conn, r["session_id"])
        if not pts or pts[-1].s < PRIVACY_TRIM_M:
            continue  # still within the first 200 m
        since = r["updated_at"] - dt.timedelta(seconds=LIVE_TRACK_S)
        recent = [p for p in public_points(pts, ended=False) if p.t >= since]
        rating = conn.execute(
            "SELECT t, value FROM labels WHERE session_id = %s AND type = %s ORDER BY t DESC LIMIT 5",
            (r["session_id"], SICKNESS_LABEL)).fetchall()
        latest = None
        for t, value in rating:
            try:
                latest = {"value": int(float(value)), "tUtc": iso(t)}
                break
            except (TypeError, ValueError):
                continue
        devices.append({
            "deviceId": r["device_id"],
            "sessionId": r["session_id"],
            "source": r["source"],
            "sessionStatus": r["status"],
            "vehicleType": r["vehicle_type"] or "unknown",
            "updatedAt": iso(r["updated_at"]),
            "receivedAt": iso(r["received_at"]),
            "lat": rnd(r["lat"]),
            "lon": rnd(r["lon"]),
            "speedMs": rnd(r["speed_ms"], 2),
            "courseDeg": rnd(r["course_deg"], 1),
            "hAccM": rnd(r["h_acc_m"], 1),
            "roughnessNow": rnd(r["roughness_now"], 3),
            "msdvSoFar": rnd(r["msdv_so_far"], 3),
            "latestRating": latest,
            "battery": rnd(r["battery"], 2),
            "thermal": r["thermal"],
            "track": [[rnd(p.lon), rnd(p.lat)] for p in recent],
        })
    return {"serverTime": iso(now), "devices": devices}


# --- Aggregates (empty until the processing step exists) ---------------------------------

def overview(conn: Connection) -> dict:
    total, upload, live_n, replay, included, mock = conn.execute("""
        SELECT count(*), count(*) FILTER (WHERE source = 'upload'), count(*) FILTER (WHERE source = 'live'),
               count(*) FILTER (WHERE source = 'replay'), count(*) FILTER (WHERE include_in_agg),
               count(*) FILTER (WHERE synthetic_sensors)
        FROM sessions
        """).fetchone()
    return {
        "sessions": {"total": total, "upload": upload, "live": live_n, "replay": replay,
                     "includedInAgg": included, "mock": mock},
        "distanceKm": 0.0,  # distance of aggregated (finalized) trips; none yet
        "segments": 0,
        "confirmedPotholes": 0,
        "speedBumps": 0,
        "lastProcessedAt": None,
        "aggregation": {"method": "none", "beta": None, "refSpeedKmh": REF_SPEED_KMH,
                        "vehicleEffects": {}, "fittedAt": None},
    }


def segment_detail(h3: str) -> dict:
    if not is_h3_cell(h3):
        raise BadRequest(f"{h3} is not an H3 cell")
    raise NotFound(f"segment {h3} has no observations")


def is_h3_cell(value: str) -> bool:
    """H3 cell index: 15 hex digits, mode 1 (cell), so the first digit is 8."""
    if len(value) != 15 or value[0] != "8":
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return True
