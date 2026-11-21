"""SQL and row → JSON for every route of dashboard/API.md.

Aggregates (segments, segment_agg, segment_sickness, aggregation_fit) are written by the finalize and
aggregate jobs; until a trip is finalized those routes answer with valid, empty shapes. Field names,
defaults and rules follow the dashboard's types (src/types/) and its mock backend (src/mock/), which is
the working spec.
"""

from __future__ import annotations

import datetime as dt
import json
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
       s.late_batches, s.duplicate_batches, s.msdv_z, s.valid_fraction, s.quality, s.finalized_at,
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


def _summary(r: dict, event_counts: dict | None = None) -> dict:
    mount = _merge(MOUNT_DEFAULTS, r["mount"])
    msdv = rnd(r["msdv_z"], 4)
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
        "validFraction": rnd(r["valid_fraction"], 4),  # set by the finalize job's quality checks
        "includeInAgg": bool(r["include_in_agg"]),
        "exclusionReasons": list(r["exclusion_reasons"] or []),
        "roughnessEligible": roughness_eligible,
        "sicknessExperimental": not roughness_eligible,
        "msdvZ": msdv,  # ISO 2631-1 Wf, vertical, so far (live) or whole trip
        "msiPct": None if msdv is None else round(msdv / 3, 4),  # API.md: MSI % ≈ MSDV / 3
        "eventCounts": event_counts or {"pothole": 0, "speed_bump": 0, "rail_joint": 0},
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
    stored = r["quality"] if isinstance(r["quality"], dict) else {}  # written by the finalize job
    invalid = {"phone_moved": 0, "gravity_drift": 0, "gyro_gps_mismatch": 0, "gps_poor": 0}
    invalid.update({k: v for k, v in (stored.get("invalidSeconds") or {}).items() if k in invalid})
    return {
        "streams": stored.get("streams") or {},  # per-stream rates need the full trip: finalize job
        "gps": {"fixes": int(fixes), "medianHAccM": rnd(median, 2), "p95HAccM": rnd(p95, 2)},
        "validFraction": rnd(r["valid_fraction"], 4),
        "invalidSeconds": invalid,
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


def _counts(features: list[dict]) -> dict:
    counts = {t: 0 for t in EVENT_TYPES}
    for f in features:
        counts[f["properties"]["type"]] += 1
    return counts


def _summary_with_counts(conn: Connection, r: dict) -> dict:
    return _summary(r, _counts(public_events(conn, r)))


def session_list(conn: Connection, source: str | None, vehicle: str | None) -> dict:
    sql = SESSION_SQL + " WHERE (%s::text IS NULL OR s.source = %s) AND (%s::text IS NULL OR s.vehicle_type = %s)" \
                        " ORDER BY COALESCE(s.started_at, s.created_at) DESC"
    rows = _rows(conn, sql, (SICKNESS_LABEL, source, source, vehicle, vehicle))
    return {"sessions": [_summary_with_counts(conn, r) for r in rows]}


def session_detail(conn: Connection, session_id: str) -> dict:
    r = _session_row(conn, session_id)
    return {
        **_summary_with_counts(conn, r),
        "quality": _quality(conn, r),
        "detection": None,
        "sickness": {"msdvZ": rnd(r["msdv_z"], 4),
                     "msiPct": None if r["msdv_z"] is None else round(r["msdv_z"] / 3, 4),
                     "ratings": _ratings(conn, session_id), "spearman": None},
        "processedAt": iso(r["finalized_at"]),
        "processorVersion": None,
    }


def quality_list(conn: Connection) -> dict:
    rows = _rows(conn, SESSION_SQL + " ORDER BY COALESCE(s.started_at, s.created_at) DESC", (SICKNESS_LABEL,))
    return {"sessions": [{**_summary_with_counts(conn, r), "quality": _quality(conn, r)} for r in rows]}


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
    rows = conn.execute(
        "SELECT t, a_vert, a_lat, a_lon, speed_ms, msdv FROM session_series WHERE session_id = %s ORDER BY t",
        (session_id,)).fetchall()
    return {
        "t": [epoch_ms(t) for t, *_ in rows],
        "aVert": [rnd(r[1], 4) for r in rows],
        "aLat": [rnd(r[2], 4) for r in rows],
        "aLon": [rnd(r[3], 4) for r in rows],
        "speed": [rnd(r[4], 2) for r in rows],
        "msdv": [rnd(r[5], 5) for r in rows],
    }


def public_events(conn: Connection, r: dict) -> list[dict]:
    """The trip's events as GeoJSON features, minus those inside the private first/last 200 m."""
    rows = conn.execute(
        """
        SELECT type, t, ST_X(geom::geometry), ST_Y(geom::geometry), speed_ms, magnitude, confidence,
               matched_label
        FROM events WHERE session_id = %s AND geom IS NOT NULL ORDER BY t
        """, (r["session_id"],)).fetchall()
    if not rows:
        return []
    pts = track_points(conn, r["session_id"])
    if not pts:
        return []
    ended = r["status"] != "live"
    total = pts[-1].s
    features = []
    for etype, t, lon, lat, speed, magnitude, confidence, matched in rows:
        s = _distance_at(pts, t)
        if s < PRIVACY_TRIM_M or (ended and s > total - PRIVACY_TRIM_M):
            continue
        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [rnd(lon), rnd(lat)]},
            "properties": {
                "id": f"{r['session_id']}:{etype}:{epoch_ms(t)}",
                "sessionId": r["session_id"],
                "type": etype,
                "tUtc": iso(t),
                "speedKmh": None if speed is None else round(speed * 3.6, 1),
                "magnitude": rnd(magnitude, 3),
                "confidence": rnd(confidence, 3),
                "matchedLabel": bool(matched),
                "vehicleType": r["vehicle_type"] or "unknown",
            },
        })
    return features


def _distance_at(pts: list[TrackPoint], t: dt.datetime) -> float:
    """Distance travelled at time t, from the nearest earlier fix (the first fix if t is before it)."""
    best = pts[0].s
    for p in pts:
        if p.t > t:
            break
        best = p.s
    return best


def session_events(conn: Connection, session_id: str) -> dict:
    r = _session_row(conn, session_id)
    return {"type": "FeatureCollection", "features": public_events(conn, r)}


def all_events(conn: Connection, vehicle: str | None, etype: str | None) -> dict:
    """Events of aggregated trips only (API.md), optionally one vehicle type and one event type."""
    sql = SESSION_SQL + " WHERE s.include_in_agg AND (%s::text IS NULL OR s.vehicle_type = %s)"
    vt = None if vehicle in (None, "all") else vehicle
    features = []
    for r in _rows(conn, sql, (SICKNESS_LABEL, vt, vt)):
        features += [f for f in public_events(conn, r) if etype is None or f["properties"]["type"] == etype]
    return {"type": "FeatureCollection", "features": features}


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


# --- Aggregates (written by the finalize and aggregate jobs) ------------------------------

def _aggregation_info(conn: Connection) -> dict:
    row = conn.execute("SELECT method, beta, vehicle_effects, fitted_at FROM aggregation_fit").fetchone()
    if row is None:
        return {"method": "none", "beta": None, "refSpeedKmh": REF_SPEED_KMH, "vehicleEffects": {},
                "fittedAt": None}
    method, beta, effects, fitted_at = row
    return {"method": method, "beta": rnd(beta, 4), "refSpeedKmh": REF_SPEED_KMH,
            "vehicleEffects": {k: rnd(v, 4) for k, v in (effects or {}).items()}, "fittedAt": iso(fitted_at)}


def overview(conn: Connection) -> dict:
    total, upload, live_n, replay, included, mock, distance_m, last_processed = conn.execute("""
        SELECT count(*), count(*) FILTER (WHERE source = 'upload'), count(*) FILTER (WHERE source = 'live'),
               count(*) FILTER (WHERE source = 'replay'), count(*) FILTER (WHERE include_in_agg),
               count(*) FILTER (WHERE synthetic_sensors),
               COALESCE(sum(distance_m) FILTER (WHERE include_in_agg), 0), max(finalized_at)
        FROM sessions
        """).fetchone()
    segments, confirmed = conn.execute(
        "SELECT count(*), count(*) FILTER (WHERE pothole_confirmed) FROM segment_agg WHERE vehicle_type = 'all'"
    ).fetchone()
    speed_bumps = conn.execute(
        "SELECT count(*) FROM events e JOIN sessions s USING (session_id) "
        "WHERE s.include_in_agg AND e.type = 'speed_bump'").fetchone()[0]
    return {
        "sessions": {"total": total, "upload": upload, "live": live_n, "replay": replay,
                     "includedInAgg": included, "mock": mock},
        "distanceKm": round(float(distance_m) / 1000, 1),  # finalized trips in the aggregates
        "segments": segments,
        "confirmedPotholes": confirmed,
        "speedBumps": speed_bumps,
        "lastProcessedAt": iso(last_processed),
        "aggregation": _aggregation_info(conn),
    }


AGG_COLUMNS = """a.h3, a.vehicle_type, a.n_sessions, a.n_passes, a.mean_speed_kmh, a.roughness, a.roughness_pctl,
       a.roughness_method, a.pothole_hits, a.pothole_passes, a.pothole_ratio, a.pothole_confirmed,
       a.sickness_aw_rms, a.msi_1h_pct, a.sickness_sessions"""


def _aggregate(r: dict) -> dict:
    """One segment_agg row as API.md SegmentAggregate."""
    return {
        "h3": r["h3"],
        "vehicleType": r["vehicle_type"],
        "nSessions": r["n_sessions"],
        "nPasses": r["n_passes"],
        "meanSpeedKmh": rnd(r["mean_speed_kmh"], 1),
        "roughness": rnd(r["roughness"], 4),
        "roughnessPctl": rnd(r["roughness_pctl"], 4),
        "roughnessMethod": r["roughness_method"],
        "potholeHits": r["pothole_hits"],
        "potholePasses": r["pothole_passes"],
        "potholeRatio": rnd(r["pothole_ratio"], 4),
        "potholeConfirmed": bool(r["pothole_confirmed"]),
        "sicknessAwRms": rnd(r["sickness_aw_rms"], 4),
        "msi1hPct": rnd(r["msi_1h_pct"], 4),
        "sicknessSessions": r["sickness_sessions"],
    }


def segments(conn: Connection, vehicle: str | None) -> dict:
    rows = _rows(conn, f"""
        SELECT {AGG_COLUMNS}, ST_AsGeoJSON(g.boundary::geometry, 6) AS boundary
        FROM segment_agg a JOIN segments g USING (h3)
        WHERE a.vehicle_type = %s ORDER BY a.h3
        """, (vehicle or "all",))
    return {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": json.loads(r["boundary"]), "properties": _aggregate(r)} for r in rows]}


def segment_detail(conn: Connection, h3: str) -> dict:
    if not is_h3_cell(h3):
        raise BadRequest(f"{h3} is not an H3 cell")
    center = conn.execute("SELECT ST_X(center::geometry), ST_Y(center::geometry) FROM segments WHERE h3 = %s",
                          (h3,)).fetchone()
    if center is None:
        raise NotFound(f"segment {h3} has no observations")
    order = "CASE a.vehicle_type WHEN 'all' THEN 0 WHEN 'car' THEN 1 WHEN 'bus' THEN 2 WHEN 'tram' THEN 3 ELSE 4 END"
    by_vehicle = [_aggregate(r) for r in _rows(
        conn, f"SELECT {AGG_COLUMNS} FROM segment_agg a WHERE a.h3 = %s ORDER BY {order}", (h3,))]
    sickness = [{
        "vehicleType": vt, "raterSeat": seat, "raterPosture": posture, "sicknessAwRms": rnd(aw, 4),
        "msi1hPct": rnd(msi, 4), "nSessions": n,
    } for vt, seat, posture, aw, msi, n in conn.execute(
        "SELECT vehicle_type, rater_seat, rater_posture, sickness_aw_rms, msi_1h_pct, n_sessions "
        "FROM segment_sickness WHERE h3 = %s ORDER BY vehicle_type, rater_seat, rater_posture", (h3,)).fetchall()]
    # Every pass outside the private first/last 200 m; trips not (yet) in the aggregates are flagged.
    observations = [{
        "sessionId": sid, "vehicleType": vt or "unknown", "tStart": iso(t), "speedKmh": None if v is None else round(v * 3.6, 1),
        "roughnessRms": rnd(rough, 4), "awRms": rnd(aw, 4), "potholeCount": potholes, "includedInAgg": bool(inc),
    } for sid, vt, t, v, rough, aw, potholes, inc in conn.execute(
        """
        SELECT o.session_id, s.vehicle_type, o.t_start, o.mean_speed_ms, o.roughness_rms, o.aw_rms,
               o.pothole_count, s.include_in_agg
        FROM segment_observations o JOIN sessions s USING (session_id)
        WHERE o.h3 = %s AND NOT o.in_privacy_zone ORDER BY o.t_start
        """, (h3,)).fetchall()]
    fitted = conn.execute("SELECT fitted_at FROM aggregation_fit").fetchone()
    return {
        "h3": h3,
        "center": {"lon": rnd(center[0]), "lat": rnd(center[1])},
        "byVehicle": by_vehicle,
        "sicknessBySeat": sickness,
        "observations": observations,
        "updatedAt": iso(fitted[0]) if fitted else None,
    }


def is_h3_cell(value: str) -> bool:
    """H3 cell index: 15 hex digits, mode 1 (cell), so the first digit is 8."""
    if len(value) != 15 or value[0] != "8":
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return True
