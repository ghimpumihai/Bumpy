"""The aggregation step (plan §9 "Across sessions"): combines the segment observations of every
included trip into `segment_agg`, `segment_sickness`, `segments` and `aggregation_fit`.

It runs at the end of every finalize job and on its own as the aggregate job (RUN_MODE=aggregate),
for example after the method changes. It rebuilds everything in one transaction under an advisory
lock, so overlapping finalize jobs (up to 3) wait for each other instead of interleaving.

The method is a port of the dashboard's mock (dashboard/src/mock/aggregate.ts), whose tests pin it:
- Roughness is normalized per vehicle with one fixed-effects fit across all observations,
  log(roughness) = segment + vehicle + β·log(speed / 10 m/s), with car as the reference vehicle.
  Demeaning within each segment removes the segment effects; segments with one observation carry no
  information about β or the vehicles. With too little overlap the fallback is per-session percentiles.
- Potholes are crowd-confirmed: at least k passes with a detection and a ratio of all passes above
  15 km/h, with thresholds per vehicle type.
  Only vehicles linked to the car through shared segments are in the fit (D45): any other has no
  identifiable effect, so its observations get no car-equivalent roughness instead of switching the
  model off for everyone. Without such a link to the car at all, the fallback stays.
- Sickness is not normalized: a_w RMS weighted by moving, valid time (D45), over rigid-mount trips with
  known context.
"""

from __future__ import annotations

import logging
import math
from collections import defaultdict
from dataclasses import dataclass, field

import numpy as np
from psycopg import Connection
from psycopg.types.json import Jsonb

log = logging.getLogger(__name__)

LOCK_ID = 7_202_611_22  # shared by every aggregation run (finalize and aggregate jobs)

H3_RESOLUTION = 11  # dashboard/src/constants/map.ts
REFERENCE_SPEED_MS = 10.0  # roughness is reported for 36 km/h
MIN_ROUGHNESS_SPEED_MS = 2.0  # below this, roughness says more about the engine than the road
MIN_WITHIN_OBSERVATIONS = 30  # fewer in multi-pass segments → the fit is not trusted
REFERENCE_VEHICLE = "car"
MSDV_PER_MSI_PERCENT = 3.0  # MSI (% who may vomit) ≈ MSDV / 3
POTHOLE_MIN_SPEED_MS = 15 / 3.6
VEHICLE_FILTERS = ("car", "bus", "tram")
POTHOLE_THRESHOLDS = {  # (min hits, min ratio); same as the mock
    "all": (2, 0.5),
    "car": (2, 0.5),
    "bus": (2, 0.4),
    "tram": (3, 0.6),
}


@dataclass
class Obs:
    session_id: str
    h3: str
    vehicle: str
    duration_s: float
    speed: float | None
    roughness: float | None
    aw_rms: float
    pothole_count: int
    roughness_eligible: bool
    sickness_eligible: bool
    rater_seat: str = "unknown"
    rater_posture: str = "unknown"
    percentile: float | None = None
    # Moving, valid time of the pass and its a_w over that time (D45). None for observations
    # finalized before these existed: they fall back to the whole pass.
    sickness_s: float | None = None
    sickness_aw_rms: float | None = None

    @property
    def rough_usable(self) -> bool:
        return (self.roughness_eligible and bool(self.roughness) and self.speed is not None
                and self.speed >= MIN_ROUGHNESS_SPEED_MS)

    @property
    def sickness_weight(self) -> tuple[float, float]:
        """(seconds, a_w RMS over them) this pass contributes to sickness."""
        if self.sickness_s is None:
            return self.duration_s, self.aw_rms
        return self.sickness_s, self.sickness_aw_rms or 0.0


@dataclass
class Fit:
    beta: float
    effects: dict[str, float]


@dataclass
class Result:
    method: str
    fit: Fit | None
    n_observations: int
    n_sessions: int
    aggs: list[dict] = field(default_factory=list)
    sickness: list[dict] = field(default_factory=list)


def eligible(context_known: bool, mount: dict | None) -> bool:
    """Rigid mount and known context: counts for roughness and potholes, and its sickness numbers
    aren't experimental (plan §10; mock dataset.ts isRoughnessEligible / isSicknessExperimental)."""
    mount = mount or {}
    # Same rule as the read API's roughnessEligible: rigid must be stated, not just not denied.
    return bool(context_known) and mount.get("rigid") is True and mount.get("handheld") is not True


# --- Method ---------------------------------------------------------------------------------

def identified_vehicles(usable: list[Obs]) -> set[str]:
    """The vehicles whose effect relative to the car can be estimated: those connected to it through
    segments where both have observations (directly or through a chain of other vehicles). Empty
    when the car itself isn't in any multi-pass segment."""
    in_cell: dict[str, set[str]] = defaultdict(set)
    counts: dict[str, int] = defaultdict(int)
    for r in usable:
        in_cell[r.h3].add(r.vehicle)
        counts[r.h3] += 1
    multi = [vs for cell, vs in in_cell.items() if counts[cell] >= 2]
    if not any(REFERENCE_VEHICLE in vs for vs in multi):
        return set()
    linked = {REFERENCE_VEHICLE}
    grew = True
    while grew:
        grew = False
        for vs in multi:
            if vs & linked and not vs <= linked:
                linked |= vs
                grew = True
    return linked


def fit_roughness(rows: list[Obs]) -> Fit | None:
    usable = [r for r in rows if r.rough_usable]
    linked = identified_vehicles(usable)
    usable = [r for r in usable if r.vehicle in linked]
    vehicles = sorted(linked - {REFERENCE_VEHICLE})
    by_cell: dict[str, list[Obs]] = defaultdict(list)
    for r in usable:
        by_cell[r.h3].append(r)

    size = 1 + len(vehicles)
    xtx = np.zeros((size, size))
    xty = np.zeros(size)
    within = 0
    for group in by_cell.values():
        if len(group) < 2:
            continue
        within += len(group)
        x = np.array([[math.log(r.speed / REFERENCE_SPEED_MS)] + [1.0 if r.vehicle == v else 0.0 for v in vehicles]
                      for r in group])
        y = np.array([math.log(r.roughness) for r in group])
        dx, dy = x - x.mean(axis=0), y - y.mean()
        xtx += dx.T @ dx
        xty += dx.T @ dy
    if within < MIN_WITHIN_OBSERVATIONS:
        return None
    # Same guard as the mock's Gaussian elimination: a vehicle (or speed) that never varies within
    # a segment can't be separated from the segment effects.
    if np.linalg.matrix_rank(xtx, tol=1e-9) < size:
        return None
    solution = np.linalg.solve(xtx, xty)
    effects = {REFERENCE_VEHICLE: 0.0}
    for i, v in enumerate(vehicles):
        effects[v] = float(solution[i + 1])
    return Fit(beta=float(solution[0]), effects=effects)


def _percent_ranks(rows: list[Obs]) -> None:
    """Per session, over the passes the percentile mean uses (rough_usable, so idle passes don't shift
    the moving ones); equal roughness gets the average of its ranks."""
    by_session: dict[str, list[Obs]] = defaultdict(list)
    for r in rows:
        if r.rough_usable:
            by_session[r.session_id].append(r)
    for group in by_session.values():
        ordered = sorted(group, key=lambda r: r.roughness)
        n = len(ordered)
        i = 0
        while i < n:
            j = i
            while j + 1 < n and ordered[j + 1].roughness == ordered[i].roughness:
                j += 1
            for k in range(i, j + 1):
                ordered[k].percentile = (i + j) / 2 / (n - 1) if n > 1 else 0.5
            i = j + 1


def _mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _aw(rows: list[Obs]) -> float | None:
    weights = [r.sickness_weight for r in rows]
    duration = sum(s for s, _ in weights)
    return math.sqrt(sum(aw ** 2 * s for s, aw in weights) / duration) if duration > 0 else None


def _sick(rows: list[Obs]) -> list[Obs]:
    """Eligible passes with moving, valid time in them."""
    return [r for r in rows if r.sickness_eligible and r.sickness_weight[0] > 0]


def _msi_1h(aw: float | None) -> float | None:
    return None if aw is None else aw * math.sqrt(3600) / MSDV_PER_MSI_PERCENT


def _group(cell: str, filt: str, rows: list[Obs], method: str, fit: Fit | None) -> dict:
    rough = [r for r in rows if r.rough_usable]
    fitted = [r for r in rough if fit and r.vehicle in fit.effects]
    normalized = None
    if method == "model" and fitted:
        normalized = math.exp(sum(
            math.log(r.roughness) - fit.effects[r.vehicle]
            - fit.beta * math.log(r.speed / REFERENCE_SPEED_MS) for r in fitted) / len(fitted))
    passes = [r for r in rows if r.roughness_eligible and r.speed is not None and r.speed > POTHOLE_MIN_SPEED_MS]
    hits = sum(1 for r in passes if r.pothole_count > 0)
    ratio = hits / len(passes) if passes else None
    min_hits, min_ratio = POTHOLE_THRESHOLDS.get(filt, POTHOLE_THRESHOLDS["all"])
    sick = _sick(rows)
    aw = _aw(sick)
    speeds = [r.speed * 3.6 for r in rows if r.speed is not None]
    return {
        "h3": cell, "vehicle_type": filt,
        "n_sessions": len({r.session_id for r in rows}), "n_passes": len(rows),
        "mean_speed_kmh": _mean(speeds),
        "roughness": normalized,
        "roughness_pctl": _mean([r.percentile for r in rough if r.percentile is not None]),
        # Only vehicles outside the fit here: no car-equivalent, so the cell shows its percentile.
        "roughness_method": ("percentile" if method == "model" and not fitted else method) if rough else "none",
        "pothole_hits": hits, "pothole_passes": len(passes), "pothole_ratio": ratio,
        "pothole_confirmed": hits >= min_hits and (ratio or 0.0) >= min_ratio,
        "sickness_aw_rms": aw, "msi_1h_pct": _msi_1h(aw),
        "sickness_sessions": len({r.session_id for r in sick}),
    }


def _sickness_splits(cell: str, rows: list[Obs]) -> list[dict]:
    groups: dict[tuple[str, str, str], list[Obs]] = defaultdict(list)
    for r in _sick(rows):
        groups[(r.vehicle, r.rater_seat, r.rater_posture)].append(r)
    out = []
    for (vehicle, seat, posture), group in groups.items():
        aw = _aw(group)
        out.append({"h3": cell, "vehicle_type": vehicle, "rater_seat": seat, "rater_posture": posture,
                    "sickness_aw_rms": aw, "msi_1h_pct": _msi_1h(aw),
                    "n_sessions": len({r.session_id for r in group})})
    return out


def compute(rows: list[Obs]) -> Result:
    _percent_ranks(rows)
    fit = fit_roughness(rows)
    method = "none" if not rows else ("model" if fit else "percentile")
    result = Result(method=method, fit=fit, n_observations=len(rows),
                    n_sessions=len({r.session_id for r in rows}))
    by_cell: dict[str, list[Obs]] = defaultdict(list)
    for r in rows:
        by_cell[r.h3].append(r)
    for cell, cell_rows in sorted(by_cell.items()):
        result.aggs.append(_group(cell, "all", cell_rows, method, fit))
        for filt in VEHICLE_FILTERS:
            subset = [r for r in cell_rows if r.vehicle == filt]
            if subset:
                result.aggs.append(_group(cell, filt, subset, method, fit))
        result.sickness.extend(_sickness_splits(cell, cell_rows))
    return result


# --- Database -------------------------------------------------------------------------------

def load_observations(conn: Connection) -> list[Obs]:
    rows = conn.execute(
        """
        SELECT o.session_id, o.h3, s.vehicle_type, o.duration_s, o.mean_speed_ms, o.roughness_rms,
               o.aw_rms, o.sickness_s, o.sickness_aw_rms, o.pothole_count, s.context_known, s.mount,
               COALESCE(NULLIF(s.people->>'raterSeat', ''), 'unknown'),
               COALESCE(NULLIF(s.people->>'raterPosture', ''), 'seated')  -- the app's and summary's default
        FROM segment_observations o JOIN sessions s USING (session_id)
        WHERE s.include_in_agg
        ORDER BY o.session_id, o.pass_idx
        """
    ).fetchall()
    out = []
    for sid, cell, vehicle, dur, speed, rough, aw, sick_s, sick_aw, potholes, ctx, mount, seat, posture in rows:
        ok = eligible(ctx, mount)
        out.append(Obs(session_id=sid, h3=cell, vehicle=vehicle, duration_s=dur, speed=speed,
                       roughness=rough, aw_rms=aw, pothole_count=potholes, roughness_eligible=ok,
                       sickness_eligible=ok, rater_seat=seat, rater_posture=posture,
                       sickness_s=sick_s, sickness_aw_rms=sick_aw))
    return out


def _hexagon_wkt(cell: str) -> tuple[str, str]:
    import h3

    lat, lon = h3.cell_to_latlng(cell)
    ring = [(lo, la) for la, lo in h3.cell_to_boundary(cell)]
    ring.append(ring[0])
    polygon = "POLYGON((" + ", ".join(f"{lo:.8f} {la:.8f}" for lo, la in ring) + "))"
    return f"POINT({lon:.8f} {lat:.8f})", polygon


def write(conn: Connection, result: Result) -> None:
    conn.execute("DELETE FROM segment_sickness")
    conn.execute("DELETE FROM segment_agg")
    conn.execute("DELETE FROM segments")
    cells = sorted({a["h3"] for a in result.aggs})
    with conn.cursor() as cur:
        if cells:
            cur.executemany(
                "INSERT INTO segments (h3, center, boundary) "
                "VALUES (%s, ST_GeogFromText(%s), ST_GeogFromText(%s))",
                [(c, *_hexagon_wkt(c)) for c in cells],
            )
        if result.aggs:
            cols = list(result.aggs[0].keys())
            cur.executemany(
                f"INSERT INTO segment_agg ({', '.join(cols)}) VALUES ({', '.join(['%s'] * len(cols))})",
                [tuple(a[c] for c in cols) for a in result.aggs],
            )
        if result.sickness:
            cols = list(result.sickness[0].keys())
            cur.executemany(
                f"INSERT INTO segment_sickness ({', '.join(cols)}) VALUES ({', '.join(['%s'] * len(cols))})",
                [tuple(s[c] for c in cols) for s in result.sickness],
            )
    conn.execute(
        """
        INSERT INTO aggregation_fit (id, method, beta, vehicle_effects, n_observations, n_sessions, fitted_at)
        VALUES (true, %s, %s, %s, %s, %s, now())
        ON CONFLICT (id) DO UPDATE SET method = EXCLUDED.method, beta = EXCLUDED.beta,
          vehicle_effects = EXCLUDED.vehicle_effects, n_observations = EXCLUDED.n_observations,
          n_sessions = EXCLUDED.n_sessions, fitted_at = EXCLUDED.fitted_at
        """,
        (result.method, result.fit.beta if result.fit else None,
         Jsonb(result.fit.effects if result.fit else {}), result.n_observations, result.n_sessions),
    )


def rebuild(conn: Connection) -> Result:
    """Rebuilds every aggregate in one transaction. Waits for any other run to finish first."""
    with conn.transaction():
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (LOCK_ID,))
        result = compute(load_observations(conn))
        write(conn, result)
    log.info("aggregation: method=%s beta=%s observations=%d sessions=%d segments=%d",
             result.method, f"{result.fit.beta:.3f}" if result.fit else "-", result.n_observations,
             result.n_sessions, len({a['h3'] for a in result.aggs}))
    return result


def run() -> None:
    from .db import connect

    with connect(application_name="roadride-aggregate") as conn:
        rebuild(conn)
