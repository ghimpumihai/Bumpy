"""Whole-trip checks for the finalize job (plan §9 step 3 and step 5's scoring).

- Invalid windows, per 0.2 s series window: the phone was moved or touched (the operator's
  `phone_moved` tap, or the knocks after a `sync_tap`, spec §3.7 and §5), gravity drifted away from the
  mount's orientation in the phone's frame, or the gyro's turn rate disagrees with the GPS course.
- Detections scored against the manual taps within ±1.5 s, as precision and recall (API.md
  `DetectionScore`, the same rule as the dashboard's mock).

These need the whole trip (the mount's orientation is the trip's typical one; taps come after the
event), so they run in the finalize job only, not in the live pipeline. All thresholds are
PROVISIONAL, like the pothole threshold in dsp.py.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

# Around a tap: the phone was handled a little before the operator could press the button.
PHONE_MOVED_WINDOW_S = (-5.0, 5.0)
SYNC_TAP_WINDOW_S = (-1.0, 10.0)  # "knock firmly on the phone/mount 3 times" right after the tap
GRAVITY_BIN_S = 1.0
GRAVITY_DRIFT_DEG = 15.0  # roads tilt the vehicle by a few degrees; more is the phone, not the road
GYRO_GPS_MIN_SPEED_MS = 5.0  # GPS course is noise when slow
GYRO_GPS_FIX_DT_S = (0.5, 3.0)
GYRO_GPS_MAX_DIFF_RAD_S = 0.2
GYRO_GPS_MIN_COVERAGE = 0.5  # of the 100 Hz samples between the two fixes
MOTION_HZ = 100.0
DETECTION_MATCH_S = 1.5  # plan §9 step 5: people react late
DETECTION_TYPES = ("pothole", "speed_bump")


@dataclass(frozen=True)
class Motion:
    """The trip's deviceMotion samples on UTC (epoch s), phone frame: gravity in g, rotation rad/s."""
    t: np.ndarray
    g: np.ndarray
    rr: np.ndarray


def window_mids(series_t: list[float] | np.ndarray, window_s: float) -> np.ndarray:
    """A series point's t is the end of its window."""
    return np.asarray(series_t, dtype=float) - window_s / 2


def _in_intervals(x: np.ndarray, intervals: list[tuple[float, float]]) -> np.ndarray:
    mask = np.zeros(len(x), dtype=bool)
    for lo, hi in intervals:
        mask |= (x >= lo) & (x <= hi)
    return mask


def handled(mids: np.ndarray, labels: list[tuple[float, str]]) -> np.ndarray:
    """Windows around `phone_moved` and `sync_tap` taps. labels: (epoch s, type)."""
    spans = []
    for t, typ in labels:
        if typ == "phone_moved":
            spans.append((t + PHONE_MOVED_WINDOW_S[0], t + PHONE_MOVED_WINDOW_S[1]))
        elif typ == "sync_tap":
            spans.append((t + SYNC_TAP_WINDOW_S[0], t + SYNC_TAP_WINDOW_S[1]))
    return _in_intervals(mids, spans)


def _unit(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    n[n == 0] = 1.0
    return v / n


def gravity_drift(mids: np.ndarray, m: Motion) -> np.ndarray:
    """Windows whose 1 s mean gravity direction is more than GRAVITY_DRIFT_DEG from the trip's
    typical one (the component-wise median of the 1 s means): the phone sagged, slid or was moved
    in its mount, so its axes no longer match the vehicle's."""
    out = np.zeros(len(mids), dtype=bool)
    if len(m.t) < 2:
        return out
    t0 = float(m.t.min())
    idx = np.floor((m.t - t0) / GRAVITY_BIN_S).astype(int)
    n_bins = int(idx.max()) + 1
    sums = np.zeros((n_bins, 3))
    np.add.at(sums, idx, _unit(m.g))
    counts = np.bincount(idx, minlength=n_bins)
    have = counts > 0
    means = _unit(sums[have])
    ref = _unit(np.median(means, axis=0))
    angle = np.zeros(n_bins)
    angle[have] = np.degrees(np.arccos(np.clip(means @ ref, -1.0, 1.0)))
    drift = np.zeros(n_bins, dtype=bool)
    drift[have] = angle[have] > GRAVITY_DRIFT_DEG
    w = np.floor((mids - t0) / GRAVITY_BIN_S).astype(int)
    ok = (w >= 0) & (w < n_bins)
    out[ok] = drift[w[ok]]
    return out


def gyro_gps_mismatch(mids: np.ndarray, m: Motion,
                      fixes: list[tuple[float, float | None, float | None]]) -> np.ndarray:
    """Windows between two fixes where the yaw rate from the gyro (rotation about "up") and the GPS
    course change disagree by more than GYRO_GPS_MAX_DIFF_RAD_S. fixes: (epoch s, speed, course°),
    ascending. Course grows clockwise and the yaw rate counter-clockwise, so they should cancel."""
    out = np.zeros(len(mids), dtype=bool)
    if len(m.t) < 2 or len(fixes) < 2:
        return out
    order = np.argsort(m.t, kind="stable")
    t = m.t[order]
    yaw_ccw = np.einsum("ij,ij->i", m.rr[order], -_unit(m.g[order]))
    cum = np.concatenate([[0.0], np.cumsum(yaw_ccw)])
    for (t1, v1, c1), (t2, v2, c2) in zip(fixes, fixes[1:]):
        dt = t2 - t1
        if not GYRO_GPS_FIX_DT_S[0] <= dt <= GYRO_GPS_FIX_DT_S[1]:
            continue
        if None in (v1, v2, c1, c2) or min(v1, v2) < GYRO_GPS_MIN_SPEED_MS:
            continue
        a, b = int(np.searchsorted(t, t1)), int(np.searchsorted(t, t2))
        if b - a < GYRO_GPS_MIN_COVERAGE * dt * MOTION_HZ:
            continue
        course_rate = math.radians((c2 - c1 + 180.0) % 360.0 - 180.0) / dt
        gyro_rate = (cum[b] - cum[a]) / (b - a)
        if abs(course_rate + gyro_rate) > GYRO_GPS_MAX_DIFF_RAD_S:
            out |= (mids >= t1) & (mids < t2)
    return out


def score_detections(events: list[tuple[float, str]],
                     taps: list[tuple[float, str]]) -> tuple[dict, list[bool]]:
    """API.md DetectionMetrics, and for each event whether a tap of its type is within ±1.5 s.
    Not one-to-one, like the mock: a detection is right if any tap is near it, a tap is found if any
    detection is near it. truePositives/falsePositives count detections and falseNegatives counts taps,
    so precision is over the detections and recall over the taps: a pothole detected twice (front and
    rear axle) mustn't count twice against the other taps."""
    matched = [False] * len(events)
    metrics = {}
    for typ in DETECTION_TYPES:
        det = [(i, t) for i, (t, et) in enumerate(events) if et == typ]
        tap_t = np.sort(np.asarray([t for t, lt in taps if lt == typ], dtype=float))
        det_t = np.sort(np.asarray([t for _, t in det], dtype=float))

        def near(x: float, ref: np.ndarray) -> bool:
            if not len(ref):
                return False
            j = int(np.searchsorted(ref, x))
            return any(abs(ref[k] - x) <= DETECTION_MATCH_S for k in (j - 1, j) if 0 <= k < len(ref))

        tp = 0
        for i, t in det:
            if near(t, tap_t):
                matched[i] = True
                tp += 1
        fn = sum(1 for t in tap_t if not near(float(t), det_t))
        fp = len(det) - tp
        found = len(tap_t) - fn
        metrics[typ] = {
            "truePositives": tp, "falsePositives": fp, "falseNegatives": fn,
            "precision": round(tp / (tp + fp), 4) if tp + fp else None,
            "recall": round(found / len(tap_t), 4) if len(tap_t) else None,
        }
    return metrics, matched
