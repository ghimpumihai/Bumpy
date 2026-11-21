"""Signal processing: filter responses, physical sanity, and chunk invariance (live batches must give
the same numbers as one pass over the whole trip)."""

import json
import math

import numpy as np
import pytest

from roadride import dsp

FS = dsp.FS
T0 = 1_795_000_000.0  # epoch seconds


def _phone_frame():
    """A fixed, tilted phone: rotation from vehicle (x fwd, y left, z up) to phone axes."""
    a, b = math.radians(25), math.radians(-40)
    rx = np.array([[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]])
    rz = np.array([[math.cos(b), -math.sin(b), 0], [math.sin(b), math.cos(b), 0], [0, 0, 1]])
    return rx @ rz


def synth(seconds, *, vert=lambda t: 0 * t, speed=lambda t: 0 * t + 12.0, lon=None, seed=1,
          jitter=True, rate=FS):
    """deviceMotion-like samples (epoch s, ua g, gravity g) and 1 Hz fixes, for a vehicle signal."""
    rng = np.random.default_rng(seed)
    n = int(seconds * rate)
    t = np.arange(n) / rate
    if jitter:
        t = t + rng.uniform(-0.002, 0.002, n)
        t.sort()
    r = _phone_frame()
    a_vehicle = np.zeros((n, 3))
    a_vehicle[:, 2] = vert(t)
    if lon is not None:
        a_vehicle[:, 0] = lon(t)
    ua = (a_vehicle @ r.T) / dsp.G
    grav = np.tile(np.array([0, 0, -1.0]) @ r.T, (n, 1))
    fixes = [(T0 + s + 0.3, float(speed(np.array(s + 0.3)))) for s in range(int(seconds))]
    return T0 + t, ua, grav, fixes


def run_whole(t, ua, grav, fixes):
    p = dsp.Pipeline()
    return p.feed(t, ua, grav, fixes), p


def run_chunked(t, ua, grav, fixes, seed=7):
    rng = np.random.default_rng(seed)
    series, events, state, out = [], [], None, None
    start = t[0]
    while start <= t[-1]:
        end = start + rng.uniform(1.0, 3.0)
        m = (t >= start) & (t < end)
        f = [x for x in fixes if start <= x[0] < end]
        p = dsp.Pipeline(json.loads(json.dumps(state)) if state else None)  # DB round trip
        out = p.feed(t[m], ua[m], grav[m], f)
        series += out.series
        events += out.events
        state = p.to_state()
        start = end
    return series, events, out


# --- Wf filter ----------------------------------------------------------------------------

def test_wf_digital_matches_analog_in_the_sickness_band():
    f = np.geomspace(0.08, 0.63, 25)
    analog, digital = dsp.wf_analog_gain(f), dsp.wf_digital_gain(f)
    assert np.max(np.abs(digital / analog - 1)) < 0.015  # bilinear warping at 20 Hz: ≈ 1 % at 0.63 Hz


def test_wf_peaks_near_017_hz_and_rejects_road_frequencies():
    f = np.geomspace(0.02, 5, 400)
    g = dsp.wf_analog_gain(f)
    assert 0.14 < f[np.argmax(g)] < 0.20  # ISO 2631 Wf peaks at ≈ 0.17 Hz
    assert dsp.wf_analog_gain(np.array([4.0]))[0] < 0.01 * g.max()
    assert dsp.wf_analog_gain(np.array([0.02]))[0] < 0.05 * g.max()


# --- Physical sanity ----------------------------------------------------------------------

def test_vertical_sign_screen_up():
    p = dsp.Pipeline()
    ua = np.array([[0.0, 0.0, 0.1]])  # 0.1 g towards the screen side
    grav = np.array([[0.0, 0.0, -1.0]])  # screen up: gravity along -z
    assert p._vert(np.hstack([ua, grav]))[0] == pytest.approx(0.1 * dsp.G)


def test_roughness_of_a_10hz_sine_is_its_rms():
    amp = 3.0
    t, ua, grav, fixes = synth(30, vert=lambda t: amp * np.sin(2 * np.pi * 10 * t))
    out, _ = run_whole(t, ua, grav, fixes)
    assert out.roughness_now == pytest.approx(amp / math.sqrt(2), rel=0.05)


def test_slow_sway_is_not_roughness():
    t, ua, grav, fixes = synth(60, vert=lambda t: 1.0 * np.sin(2 * np.pi * 0.2 * t))
    out, _ = run_whole(t, ua, grav, fixes)
    assert out.roughness_now < 0.02


def test_msdv_of_a_sine_matches_the_weighting():
    amp, f0, secs = 1.0, 0.16, 600
    t, ua, grav, fixes = synth(secs, vert=lambda t: amp * np.sin(2 * np.pi * f0 * t), jitter=False)
    out, _ = run_whole(t, ua, grav, fixes)
    expected = dsp.wf_analog_gain(np.array([f0]))[0] * amp / math.sqrt(2) * math.sqrt(secs)
    assert out.msdv == pytest.approx(expected, rel=0.05)


def _spike(at):
    return lambda t: 15.0 * np.exp(-((t - at) / 0.01) ** 2)


def test_pothole_detected_above_15_kmh():
    t, ua, grav, fixes = synth(10, vert=_spike(5.0), speed=lambda t: 0 * t + 10.0)
    out, _ = run_whole(t, ua, grav, fixes)
    (ev,) = out.events
    assert ev.type == "pothole" and abs(ev.t - (T0 + 5.0)) < 0.05 and ev.speed == pytest.approx(10.0)
    assert ev.magnitude > dsp.POTHOLE_THRESHOLD_MS2 and 0 < ev.confidence <= 1


def test_no_pothole_when_slow():
    t, ua, grav, fixes = synth(10, vert=_spike(5.0), speed=lambda t: 0 * t + 3.0)
    out, _ = run_whole(t, ua, grav, fixes)
    assert out.events == []


def test_gap_resets_filters_but_keeps_the_dose():
    a = synth(20, vert=lambda t: np.sin(2 * np.pi * 0.2 * t))
    p = dsp.Pipeline()
    p.feed(*a)
    dose = p.dose
    t, ua, grav, fixes = a
    out = p.feed(t + 25, ua, grav, [(x + 25, v) for x, v in fixes])
    assert out.reset and p.dose > dose


def test_forward_axis_learned_from_speed_changes():
    # Accelerate and brake every 10 s: dv/dt and the longitudinal acceleration agree.
    lon = lambda t: 1.5 * np.sign(np.sin(2 * np.pi * t / 20))  # noqa: E731

    def speed_from_lon(s):
        # Integrate the square wave: triangle between 10 and 25 m/s.
        phase = s % 20
        return 10 + (1.5 * phase if phase < 10 else 1.5 * (20 - phase))

    t, ua, grav, _ = synth(240, lon=lon)
    fixes = [(T0 + s + 0.3, speed_from_lon(s + 0.3)) for s in range(240)]
    out, p = run_whole(t, ua, grav, fixes)
    assert p.forward_known
    late = [pt for pt in out.series if pt.t > T0 + 120]
    corr = np.corrcoef([pt.a_lon for pt in late], [lon(np.array(pt.t - T0)) for pt in late])[0, 1]
    assert corr > 0.9


# --- One pipeline: chunked == whole ---------------------------------------------------------

def test_chunked_feed_equals_one_pass():
    rng = np.random.default_rng(3)
    noise = rng.normal(0, 0.4, 600 * 100 + 10)

    def vert(t):
        idx = np.clip((t * 100).astype(int), 0, len(noise) - 1)
        return 0.8 * np.sin(2 * np.pi * 0.18 * t) + noise[idx] + _spike(123.4)(t) + _spike(400.0)(t)

    t, ua, grav, fixes = synth(600, vert=vert, speed=lambda t: 12 + 5 * np.sin(t / 30))
    whole, _ = run_whole(t, ua, grav, fixes)
    series, events, last = run_chunked(t, ua, grav, fixes)

    assert len(series) == len(whole.series) > 2900
    for a, b in zip(series, whole.series):
        assert a.t == pytest.approx(b.t, abs=1e-9)
        assert a.a_vert == pytest.approx(b.a_vert, abs=1e-6)
        assert a.msdv == pytest.approx(b.msdv, rel=1e-6, abs=1e-9)
        assert (a.speed is None) == (b.speed is None)
    assert [(round(e.t, 6), e.type) for e in events] == [(round(e.t, 6), e.type) for e in whole.events]
    assert len(events) == 2
    assert last.msdv == pytest.approx(whole.msdv, rel=1e-6)
    assert last.roughness_now == pytest.approx(whole.roughness_now, rel=1e-6)


def test_state_is_json():
    t, ua, grav, fixes = synth(5)
    p = dsp.Pipeline()
    p.feed(t, ua, grav, fixes)
    assert json.loads(json.dumps(p.to_state())) == p.to_state()
