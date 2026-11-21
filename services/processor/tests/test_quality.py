"""Whole-trip quality checks and detection scoring (plan §9 steps 3 and 5)."""

import math

import numpy as np
import pytest

from roadride import quality as qc

T0 = 1_795_000_000.0


def _motion(seconds, *, g=None, yaw_ccw=0.0, rate=100):
    t = T0 + np.arange(int(seconds * rate)) / rate
    grav = np.tile([0.0, 0.0, -1.0], (len(t), 1)) if g is None else g(t - T0)
    rr = np.zeros((len(t), 3))
    rr[:, 2] = yaw_ccw if np.isscalar(yaw_ccw) else yaw_ccw(t - T0)  # screen up: +z is "up"
    return qc.Motion(t=t, g=grav, rr=rr)


def _mids(seconds):
    return qc.window_mids(T0 + np.arange(1, int(seconds * 5) + 1) * 0.2, 0.2)


def test_handled_windows_around_phone_moved_and_after_sync_taps():
    mids = _mids(60)
    mask = qc.handled(mids, [(T0 + 20, "phone_moved"), (T0 + 40, "sync_tap"), (T0 + 50, "pothole")])
    assert mask.sum() * 0.2 == pytest.approx(10 + 11, abs=0.4)
    assert mask[np.searchsorted(mids, T0 + 16)] and not mask[np.searchsorted(mids, T0 + 26)]
    assert mask[np.searchsorted(mids, T0 + 49)] and not mask[np.searchsorted(mids, T0 + 52)]


def test_gravity_drift_flags_the_time_the_phone_sat_tilted():
    tilt = math.radians(30)
    tilted = np.array([0.0, math.sin(tilt), -math.cos(tilt)])

    def g(rel):
        out = np.tile([0.0, 0.0, -1.0], (len(rel), 1))
        out[(rel >= 20) & (rel < 30)] = tilted
        return out

    mids = _mids(60)
    mask = qc.gravity_drift(mids, _motion(60, g=g))
    assert mask.sum() * 0.2 == pytest.approx(10, abs=1.0)
    assert not mask[np.searchsorted(mids, T0 + 10)] and mask[np.searchsorted(mids, T0 + 25)]


def test_small_tilts_from_the_road_are_not_drift():
    def g(rel):
        a = np.radians(8 * np.sin(rel / 5))  # hills and braking: up to 8°
        return np.column_stack([np.sin(a), 0 * a, -np.cos(a)])

    assert not qc.gravity_drift(_mids(60), _motion(60, g=g)).any()


def _fixes(seconds, course, speed=12.0):
    return [(T0 + s + 0.5, speed, course(s + 0.5) % 360) for s in range(int(seconds))]


def test_gyro_agrees_with_gps_through_a_turn():
    # Turning right at 10°/s: course grows, the gyro turns clockwise (negative about "up").
    rate = math.radians(10)
    m = _motion(30, yaw_ccw=-rate)
    assert not qc.gyro_gps_mismatch(_mids(30), m, _fixes(30, lambda s: 350 + 10 * s)).any()


def test_gyro_gps_mismatch_when_the_phone_turns_on_its_own():
    # GPS goes straight while the gyro spins for 5 s (the phone rotating in a loose mount).
    m = _motion(30, yaw_ccw=lambda rel: np.where((rel >= 10) & (rel < 15), 0.6, 0.0))
    mask = qc.gyro_gps_mismatch(_mids(30), m, _fixes(30, lambda s: 0 * s + 90))
    assert mask.sum() * 0.2 == pytest.approx(6, abs=1.0)  # the 1 s fix intervals that overlap it


def test_no_gyro_gps_check_when_slow_or_without_course():
    m = _motion(30, yaw_ccw=0.6)
    assert not qc.gyro_gps_mismatch(_mids(30), m, _fixes(30, lambda s: 0 * s + 90, speed=2.0)).any()
    no_course = [(t, v, None) for t, v, _ in _fixes(30, lambda s: 0 * s)]
    assert not qc.gyro_gps_mismatch(_mids(30), m, no_course).any()


def test_detection_scores_against_taps_within_1_5_s():
    events = [(T0 + 10.0, "pothole"), (T0 + 30.0, "pothole"), (T0 + 50.0, "speed_bump")]
    taps = [(T0 + 11.4, "pothole"), (T0 + 70.0, "pothole"), (T0 + 51.6, "speed_bump"),
            (T0 + 30.2, "sickness")]
    metrics, matched = qc.score_detections(events, taps)
    assert matched == [True, False, False]
    assert metrics["pothole"] == {"truePositives": 1, "falsePositives": 1, "falseNegatives": 1,
                                  "precision": 0.5, "recall": 0.5}
    assert metrics["speed_bump"] == {"truePositives": 0, "falsePositives": 1, "falseNegatives": 1,
                                     "precision": 0.0, "recall": 0.0}


def test_recall_is_over_taps_when_one_pothole_is_detected_twice():
    # Front and rear axle 1.3 s apart both hit the first tap; the other two taps are missed.
    events = [(T0 + 10.0, "pothole"), (T0 + 11.3, "pothole")]
    taps = [(T0 + 10.5, "pothole"), (T0 + 40.0, "pothole"), (T0 + 70.0, "pothole")]
    metrics, _ = qc.score_detections(events, taps)
    assert metrics["pothole"] == {"truePositives": 2, "falsePositives": 0, "falseNegatives": 2,
                                  "precision": 1.0, "recall": 0.3333}


def test_detection_without_taps_or_detections_has_no_ratios():
    metrics, matched = qc.score_detections([], [])
    assert matched == []
    assert metrics["pothole"] == {"truePositives": 0, "falsePositives": 0, "falseNegatives": 0,
                                  "precision": None, "recall": None}
