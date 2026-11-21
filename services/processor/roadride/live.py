"""Turns ingest messages into plain facts, with no database or Azure code (unit-testable).

Batch format: IngestBatch.swift / ingest_core.contract. Every `t` array is seconds relative to the
batch start, so a sample's UTC time is t0Utc + t. Location fixes carry their own `tUtcMs`.
Speed, course and battery use -1 for "unknown".
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

UTC = dt.timezone.utc

COLUMNAR_BLOCKS = ("deviceMotion", "accelRaw", "gyroRaw", "altimeter", "audioLevel")
VEHICLE_TYPES = {"car", "bus", "tram", "bike", "boat"}
SOURCES = {"live", "upload", "replay"}


def parse_iso(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def from_ms(ms: int | float) -> dt.datetime:
    return dt.datetime.fromtimestamp(ms / 1000.0, tz=UTC)


def _non_negative(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None


@dataclass(frozen=True)
class Fix:
    t: dt.datetime
    lat: float
    lon: float
    speed_ms: float | None
    course_deg: float | None
    h_acc_m: float | None


@dataclass(frozen=True)
class Label:
    t: dt.datetime
    type: str
    value: str | None
    note: str | None


@dataclass(frozen=True)
class BatchFacts:
    session_id: str
    device_id: str
    batch_seq: int
    source: str
    t0_utc: dt.datetime
    end_utc: dt.datetime
    sample_counts: dict[str, int]
    fixes: list[Fix] = field(default_factory=list)
    labels: list[Label] = field(default_factory=list)
    battery: float | None = None
    thermal: str | None = None
    low_power: bool | None = None
    # deviceMotion for the signal processing: epoch seconds, user acceleration and gravity in g
    motion_t: list[float] = field(default_factory=list)
    motion_ua: list[tuple[float, float, float]] = field(default_factory=list)
    motion_g: list[tuple[float, float, float]] = field(default_factory=list)

    @property
    def last_fix(self) -> Fix | None:
        return max(self.fixes, key=lambda f: f.t) if self.fixes else None


def parse_batch(b: dict) -> BatchFacts:
    """`b` has already passed the ingest function's schema check."""
    t0 = from_ms(b["t0UtcMs"]) if isinstance(b.get("t0UtcMs"), int) and b["t0UtcMs"] > 0 \
        else parse_iso(b["t0Utc"])

    counts: dict[str, int] = {}
    newest_rel = 0.0
    for block in COLUMNAR_BLOCKS:
        ts = b[block]["t"]
        counts[block] = len(ts)
        if ts:
            newest_rel = max(newest_rel, max(ts))
    counts["location"] = len(b["location"])
    counts["labels"] = len(b["labels"])

    fixes = [
        Fix(t=from_ms(loc["tUtcMs"]), lat=float(loc["lat"]), lon=float(loc["lon"]),
            speed_ms=_non_negative(loc.get("speed")), course_deg=_non_negative(loc.get("course")),
            h_acc_m=_non_negative(loc.get("hAcc")))
        for loc in b["location"]
    ]
    end = t0 + dt.timedelta(seconds=newest_rel)
    if fixes:
        end = max(end, max(f.t for f in fixes))

    labels = [Label(t=t0 + dt.timedelta(seconds=lab["t"]), type=lab["type"], value=lab["value"],
                    note=lab["note"])
              for lab in b["labels"]]

    source = b.get("source") if b.get("source") in SOURCES else "live"
    device = b["device"]
    dm = b["deviceMotion"]
    t0_s = t0.timestamp()
    return BatchFacts(
        session_id=b["sessionId"], device_id=b["deviceId"], batch_seq=b["batchSeq"], source=source,
        t0_utc=t0, end_utc=end, sample_counts=counts, fixes=fixes, labels=labels,
        battery=_non_negative(device.get("battery")), thermal=device.get("thermal"),
        low_power=device.get("lowPower"),
        motion_t=[t0_s + float(x) for x in dm["t"]],
        motion_ua=list(zip(dm["ua_x"], dm["ua_y"], dm["ua_z"])),
        motion_g=list(zip(dm["g_x"], dm["g_y"], dm["g_z"])),
    )


@dataclass(frozen=True)
class SessionFacts:
    session_id: str
    device_id: str | None
    phase: str  # "start" | "stop"
    vehicle_type: str
    vehicle_make_model: str | None
    vehicle_line: str | None
    mount: dict
    people: dict
    conditions: dict | None
    audio_enabled: bool | None
    synthetic_sensors: bool
    recovered: bool
    started_at: dt.datetime | None
    ended_at: dt.datetime | None
    batch_count: int | None
    metadata: dict


def parse_session(m: dict) -> SessionFacts:
    """`m` is session.json, already checked by the ingest function. Stop copy = batchCount present."""
    vehicle = m.get("vehicle") or {}
    vtype = vehicle.get("type") if vehicle.get("type") in VEHICLE_TYPES else "unknown"
    return SessionFacts(
        session_id=m["sessionId"],
        device_id=m.get("deviceId") or None,
        phase="stop" if "batchCount" in m else "start",
        vehicle_type=vtype,
        vehicle_make_model=vehicle.get("makeModel") or None,
        vehicle_line=vehicle.get("line") or None,
        mount=m.get("mount") or {},
        people=m.get("people") or {},
        conditions=m.get("conditions") if isinstance(m.get("conditions"), dict) else None,
        audio_enabled=m.get("audioEnabled") if isinstance(m.get("audioEnabled"), bool) else None,
        synthetic_sensors=m.get("syntheticSensors") is True,
        recovered=m.get("recovered") is True,
        started_at=parse_iso(m.get("startedAtUtc")),
        ended_at=parse_iso(m.get("endedAtUtc")),
        batch_count=m.get("batchCount"),
        metadata=m,
    )


def exclusion_reasons(source: str, status: str, context_known: bool, mount: dict | None,
                      quality_status: str = "pending") -> list[str]:
    """Why a trip is kept out of the aggregated map (API.md "Session status and exclusion reasons")."""
    reasons: list[str] = []
    if source == "replay":
        reasons.append("replay")
    elif status != "complete":
        reasons.append("live_only" if source == "live" else "processing")
    if quality_status == "bad":
        reasons.append("bad_quality")
    if not context_known:
        reasons.append("unknown_context")
    mount = mount or {}
    if mount.get("rigid") is False:
        reasons.append("not_rigid")
    if mount.get("handheld") is True:
        reasons.append("handheld")
    return reasons
