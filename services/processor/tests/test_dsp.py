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


def synth(seconds, *, vert=lambda t: 0 * t, speed=lambda t: 0 * t + 12.0, lon=None, lat=None, seed=1,
          jitter=True, rate=FS):
    """deviceMotion-like samples (epoch s, ua g, gravity g) and 1 Hz fixes, for a vehicle signal.
    ua has CoreMotion's sign: minus the phone's acceleration (dsp.UA_SIGN)."""
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
    if lat is not None:
        a_vehicle[:, 1] = lat(t)
    ua = dsp.UA_SIGN * (a_vehicle @ r.T) / dsp.G
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

# --- Lateral sway (D49) ---------------------------------------------------------------------

def test_wy_digital_matches_analog_in_the_sway_band():
    f = np.geomspace(0.0315, 0.8, 25)
    analog, digital = dsp.wy_analog_gain(f), dsp.wy_digital_gain(f)
    assert np.max(np.abs(digital / analog - 1)) < 0.015


def test_wy_is_flat_to_025_hz_then_falls_12_db_per_octave():
    g = dsp.wy_analog_gain(np.array([0.06, 0.1, 0.16, 1.0, 2.0]))
    assert np.all(np.abs(20 * np.log10(g[:3])) < 1.0)  # ≈ unit gain in the flat band, like Wf at its peak
    assert 20 * np.log10(g[4] / g[3]) == pytest.approx(-12.0, abs=0.3)


def _sine(amp, f0):
    return lambda t: amp * np.sin(2 * np.pi * f0 * t)


def _run_known(t, ua, grav, fixes):
    p = dsp.Pipeline(_forward_known_state())
    return p.feed(t, ua, grav, fixes), p


def test_lateral_msdv_of_a_sine_matches_the_weighting():
    amp, f0, secs = 1.0, 0.2, 600
    t, ua, grav, fixes = synth(secs, lat=_sine(amp, f0), jitter=False)
    out, _ = _run_known(t, ua, grav, fixes)
    expected = dsp.LATERAL_K * dsp.wy_analog_gain(np.array([f0]))[0] * amp / math.sqrt(2) * math.sqrt(secs)
    assert out.msdv_y == pytest.approx(expected, rel=0.05)
    assert out.msdv_z < 0.01 * out.msdv_y  # sideways sway doesn't leak into the vertical dose
    assert out.msdv == pytest.approx(out.msdv_y, rel=1e-3)


def test_vertical_and_fore_aft_motion_are_not_lateral():
    t, ua, grav, fixes = synth(300, vert=_sine(1.0, 0.16), lon=_sine(1.0, 0.2), jitter=False)
    out, _ = _run_known(t, ua, grav, fixes)
    assert out.msdv_y < 0.01 * out.msdv_z


def test_vertical_and_lateral_doses_add():
    """The combined dose is the energy sum of the two axes, sample by sample: MSDV² = MSDV_z² + MSDV_y²,
    and the per-window doses add up to it, so segment passes and the aggregate use the same number."""
    t, ua, grav, fixes = synth(600, vert=_sine(0.8, 0.16), lat=_sine(1.2, 0.22), jitter=False)
    out, p = _run_known(t, ua, grav, fixes)
    assert out.msdv_z > 1 and out.msdv_y > 1
    assert out.msdv ** 2 == pytest.approx(out.msdv_z ** 2 + out.msdv_y ** 2, rel=1e-9)
    assert sum(pt.dose_inc for pt in out.series) == pytest.approx(out.msdv ** 2, rel=0.01)
    # Each axis alone gives its own part of the combined number.
    vz, _ = _run_known(*synth(600, vert=_sine(0.8, 0.16), jitter=False))
    vy, _ = _run_known(*synth(600, lat=_sine(1.2, 0.22), jitter=False))
    assert out.msdv_z == pytest.approx(vz.msdv, rel=1e-3)
    assert out.msdv_y == pytest.approx(vy.msdv, rel=1e-3)


def test_no_lateral_dose_before_the_forward_axis_is_known():
    t, ua, grav, fixes = synth(120, lat=_sine(1.0, 0.2))
    out, p = run_whole(t, ua, grav, fixes)
    assert not p.forward_known and out.msdv_y == 0.0 and out.msdv == pytest.approx(out.msdv_z)


def test_lateral_chunked_feed_equals_one_pass():
    t, ua, grav, fixes = synth(300, vert=_sine(0.5, 0.16), lat=_sine(1.0, 0.2))
    whole, _ = _run_known(t, ua, grav, fixes)
    rng = np.random.default_rng(11)
    state, series, start, out = _forward_known_state(), [], t[0], None
    while start <= t[-1]:
        end = start + rng.uniform(1.0, 3.0)
        m = (t >= start) & (t < end)
        p = dsp.Pipeline(json.loads(json.dumps(state)))
        out = p.feed(t[m], ua[m], grav[m], [x for x in fixes if start <= x[0] < end])
        series += out.series
        state, start = p.to_state(), end
    assert len(series) == len(whole.series)
    for a, b in zip(series, whole.series):
        assert a.msdv == pytest.approx(b.msdv, rel=1e-6, abs=1e-9)
        assert a.dose_inc == pytest.approx(b.dose_inc, rel=1e-6, abs=1e-12)
    assert out.msdv_y == pytest.approx(whole.msdv_y, rel=1e-6) and whole.msdv_y > 1
    assert out.msdv_z == pytest.approx(whole.msdv_z, rel=1e-6)


def test_a_remount_pauses_the_lateral_dose_and_keeps_what_was_counted():
    """After a phone_moved tap the forward axis is relearned: until then no sideways dose is added
    (the old axis no longer says where "sideways" is), and none of the dose so far is lost."""
    t, ua, grav, fixes = synth(60, lat=_sine(1.0, 0.2))
    tap = T0 + 30.0
    p = dsp.Pipeline(_forward_known_state())
    before = p.feed(t[t < tap], ua[t < tap], grav[t < tap], [f for f in fixes if f[0] < tap], moved=[tap - 0.5])
    assert not p.forward_known and before.msdv_y > 1
    dose_y = p.dose_y
    after = p.feed(t[t >= tap], ua[t >= tap], grav[t >= tap], [f for f in fixes if f[0] >= tap])
    assert not p.forward_known and p.dose_y == dose_y  # constant speed: nothing to relearn it from
    assert after.msdv == pytest.approx(math.hypot(after.msdv_z, after.msdv_y), rel=1e-9)


def test_a_trip_saved_before_the_lateral_dose_continues():
    t, ua, grav, fixes = synth(60, vert=_sine(1.0, 0.16), lat=_sine(1.0, 0.2))
    half = len(t) // 2
    p = dsp.Pipeline(_forward_known_state())
    p.feed(t[:half], ua[:half], grav[:half], [f for f in fixes if f[0] < t[half]])
    old = json.loads(json.dumps(p.to_state()))
    old["dose"] = old.pop("dose_z")  # the previous version's dose was vertical only
    old.pop("dose_y")
    old["grid"].pop("zi_wy")
    q = dsp.Pipeline(old)
    assert q.dose_z == q.dose and q.dose_y == 0.0
    out = q.feed(t[half:], ua[half:], grav[half:], [f for f in fixes if f[0] >= t[half]])
    assert not out.reset and out.msdv_y > 0 and out.msdv_z > p.dose_z ** 0.5
    assert out.msdv ** 2 == pytest.approx(out.msdv_z ** 2 + out.msdv_y ** 2, rel=1e-9)


def test_vertical_sign_screen_up():
    p = dsp.Pipeline()
    grav = np.array([[0.0, 0.0, -1.0]])  # screen up: gravity along -z
    # CoreMotion in free fall: the accelerometer reads 0, so userAcceleration = 0 - gravity = +1 g on z.
    free_fall = np.array([[0.0, 0.0, 1.0]])
    assert p._vert(np.hstack([free_fall * p.ua_sign, grav]))[0] == pytest.approx(-dsp.G)  # falling


def test_a_trip_saved_before_the_sign_fix_keeps_its_sign():
    assert dsp.Pipeline().ua_sign == dsp.UA_SIGN
    old = dsp.Pipeline().to_state()
    del old["ua_sign"]
    assert dsp.Pipeline(old).ua_sign == dsp.LEGACY_UA_SIGN
    assert dsp.Pipeline(dsp.Pipeline().to_state()).ua_sign == dsp.UA_SIGN


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


def _with_hole(seconds, start, length, **kw):
    """synth() with the samples of [start, start + length) s removed (a CoreMotion stall)."""
    t, ua, grav, fixes = synth(seconds, **kw)
    m = ~((t >= T0 + start) & (t < T0 + start + length))
    return t[m], ua[m], grav[m], fixes


def test_hole_inside_a_batch_resets_and_is_not_bridged():
    hole = (3.0, 0.6)  # a 0.6 s stall in the middle of one feed
    t, ua, grav, fixes = _with_hole(6, *hole, vert=lambda t: np.sin(2 * np.pi * 5 * t))
    out, p = run_whole(t, ua, grav, fixes)
    assert out.reset
    lo, hi = T0 + hole[0], T0 + hole[0] + hole[1]
    # The 5 Hz series lands on grid points: none of them may lie inside the hole (interpolated).
    times = [s.t for s in out.series]
    assert times and not any(lo < x < hi for x in times)
    assert all(b > a for a, b in zip(times, times[1:]))


def test_hole_inside_a_batch_equals_a_hole_between_batches():
    t, ua, grav, fixes = _with_hole(8, 3.0, 0.6, vert=lambda t: np.sin(2 * np.pi * 5 * t))
    whole, _ = run_whole(t, ua, grav, fixes)

    cut = int(np.searchsorted(t, T0 + 3.0))  # the first sample after the hole starts a new batch
    p = dsp.Pipeline()
    a = p.feed(t[:cut], ua[:cut], grav[:cut], [f for f in fixes if f[0] < t[cut]])
    p = dsp.Pipeline(json.loads(json.dumps(p.to_state())))
    b = p.feed(t[cut:], ua[cut:], grav[cut:], [f for f in fixes if f[0] >= t[cut]])
    assert b.reset
    split = a.series + b.series
    assert [round(s.t, 9) for s in split] == [round(s.t, 9) for s in whole.series]
    assert [s.a_vert for s in split] == pytest.approx([s.a_vert for s in whole.series], abs=1e-9)
    assert b.msdv == pytest.approx(whole.msdv, rel=1e-9)


def test_jitter_below_the_gap_threshold_does_not_reset():
    t, ua, grav, fixes = _with_hole(4, 2.0, dsp.MAX_GAP_S / 2)
    out, _ = run_whole(t, ua, grav, fixes)
    assert not out.reset


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
    # The axis itself, not only a_lon: a backwards axis gives the same a_lon (both signs flip) but
    # inverts the pitch rate, and then no speed bump is found.
    fwd = np.array(p.forward_sum) / np.linalg.norm(p.forward_sum)
    assert fwd @ (_phone_frame() @ np.array([1.0, 0.0, 0.0])) > 0.99
    late = [pt for pt in out.series if pt.t > T0 + 120]
    corr = np.corrcoef([pt.a_lon for pt in late], [lon(np.array(pt.t - T0)) for pt in late])[0, 1]
    assert corr > 0.9


def _square_lon(t):
    return 1.5 * np.sign(np.sin(2 * np.pi * t / 20))


def _square_speed(s):
    phase = s % 20  # the integral of _square_lon: a triangle between 10 and 25 m/s
    return 10 + (1.5 * phase if phase < 10 else 1.5 * (20 - phase))


def _rotation(axis, deg):
    a = math.radians(deg)
    k = np.asarray(axis, dtype=float) / np.linalg.norm(axis)
    kx = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + math.sin(a) * kx + (1 - math.cos(a)) * kx @ kx


def _remounted(seconds, at, rot):
    """synth() with speed changes, and the phone turned in its mount by `rot` (vehicle frame) at `at`.
    Returns the samples, the fixes and the true forward axis in the phone frame after the turn."""
    t, ua, grav, _ = synth(seconds, lon=_square_lon)
    fixes = [(T0 + s + 0.3, _square_speed(s + 0.3)) for s in range(seconds)]
    r = _phone_frame()
    m = r @ rot.T @ r.T  # old phone frame → new phone frame
    after = t - T0 >= at
    ua, grav = ua.copy(), grav.copy()
    ua[after], grav[after] = ua[after] @ m.T, grav[after] @ m.T
    return t, ua, grav, fixes, r @ rot.T @ np.array([1.0, 0.0, 0.0])


def _axis_cos(p, fwd):
    f = np.array(p.forward_sum)
    return float(f @ fwd / np.linalg.norm(f))


def test_phone_moved_tap_restarts_the_forward_axis():
    t, ua, grav, fixes = synth(240, lon=_square_lon)
    fixes = [(T0 + s + 0.3, _square_speed(s + 0.3)) for s in range(240)]
    tap = T0 + 120.0
    p = dsp.Pipeline()
    p.feed(t[t < tap + 2], ua[t < tap + 2], grav[t < tap + 2], [f for f in fixes if f[0] < tap + 2], moved=[tap])
    assert not p.forward_known  # forgotten at the tap, and the handled phone's next seconds don't count
    p.feed(t[t >= tap + 2], ua[t >= tap + 2], grav[t >= tap + 2], [f for f in fixes if f[0] >= tap + 2])
    assert p.forward_known and _axis_cos(p, _phone_frame() @ np.array([1.0, 0.0, 0.0])) > 0.99


def test_a_tilting_remount_restarts_the_forward_axis():
    # Rolled 30° and turned 45° in the mount: gravity moves in the phone frame, so the axis starts over.
    t, ua, grav, fixes, fwd = _remounted(480, 240, _rotation((1, 0, 0), 30) @ _rotation((0, 0, 1), 45))
    p = dsp.Pipeline()
    p.feed(t[t < T0 + 250], ua[t < T0 + 250], grav[t < T0 + 250], [f for f in fixes if f[0] < T0 + 250])
    assert p.forward_n < dsp.FWD_MIN_EVIDENCE  # restarted within the first seconds after the turn
    p.feed(t[t >= T0 + 250], ua[t >= T0 + 250], grav[t >= T0 + 250], [f for f in fixes if f[0] >= T0 + 250])
    assert _axis_cos(p, fwd) > 0.99


def test_remount_handling_is_the_same_chunked():
    t, ua, grav, fixes, _ = _remounted(400, 150, _rotation((0, 0, 1), 90))
    taps = [T0 + 300.5]
    whole = dsp.Pipeline()
    ref = whole.feed(t, ua, grav, fixes, moved=taps)
    rng = np.random.default_rng(3)
    state, series, start = None, [], t[0]
    while start <= t[-1]:
        end = start + rng.uniform(1.0, 3.0)
        m = (t >= start) & (t < end)
        p = dsp.Pipeline(json.loads(json.dumps(state)) if state else None)
        out = p.feed(t[m], ua[m], grav[m], [f for f in fixes if start <= f[0] < end],
                     moved=[x for x in taps if start <= x < end])
        series += out.series
        state, start = p.to_state(), end
    assert [s.a_lon for s in series] == pytest.approx([s.a_lon for s in ref.series], abs=1e-9)
    assert state["forward_sum"] == pytest.approx(whole.forward_sum, abs=1e-9)
    assert state["forward_n"] == whole.forward_n


def _stop_and_go(brake_at=180, stop_s=50.0, turn=None, yaw_rate=None, seconds=420):
    """Square-wave driving, braking at `brake_at` (a multiple of 20 s, where the triangle is at 10 m/s)
    to a stop of `stop_s`, then back to 10 m/s and the square wave; 1.5 m/s² both ways. Optionally the
    optionally the phone turned about the vertical during the stop: turn = (start s, end s, degrees).
    yaw_rate(t) adds the vehicle's own rotation about the vertical (rad/s). Returns synth()'s samples
    with a rotation rate, the fixes and the true forward axis at the end, in the phone frame."""
    grid = np.arange(0, seconds + 1, 0.01)
    stop = (brake_at + 20 / 3, brake_at + 20 / 3 + stop_s)
    lon = _square_lon(grid)
    lon[(grid >= brake_at) & (grid < stop[0])] = -1.5
    lon[(grid >= stop[0]) & (grid < stop[1])] = 0.0
    lon[(grid >= stop[1]) & (grid < stop[1] + 20 / 3)] = 1.5
    resume = grid >= stop[1] + 20 / 3
    lon[resume] = _square_lon(grid[resume] - (stop[1] + 20 / 3))
    speed = np.maximum(0.0, 10 + np.cumsum(lon) * 0.01)
    t, ua, grav, _ = synth(seconds, lon=lambda x: np.interp(x, grid, lon))
    fixes = [(T0 + s + 0.3, float(np.interp(s + 0.3, grid, speed))) for s in range(seconds)]
    rel = t - T0
    wz = np.zeros_like(rel) if yaw_rate is None else yaw_rate(rel)
    r, fwd = _phone_frame(), _phone_frame() @ np.array([1.0, 0.0, 0.0])
    if turn is not None:
        a, b, deg = turn
        during = (rel >= a) & (rel < b)
        wz[during] += math.radians(deg) / (b - a)
        m = r @ _rotation((0, 0, 1), deg).T @ r.T
        after = rel >= b
        ua, grav = ua.copy(), grav.copy()
        ua[after], grav[after] = ua[after] @ m.T, grav[after] @ m.T
        fwd = m @ fwd
    rr = np.column_stack([0 * rel, 0 * rel, wz]) @ r.T
    return t, ua, grav, fixes, rr, fwd


def test_a_phone_turned_in_its_mount_at_a_stop_restarts_the_axis():
    t, ua, grav, fixes, rr, fwd = _stop_and_go(turn=(205.0, 207.0, 90.0))
    p = dsp.Pipeline()
    p.feed(t[t < T0 + 210], ua[t < T0 + 210], grav[t < T0 + 210], [f for f in fixes if f[0] < T0 + 210],
           rr=rr[t < T0 + 210])
    assert p.forward_n == 0  # gravity didn't move: only the rotation during the stop shows it
    p.feed(t[t >= T0 + 210], ua[t >= T0 + 210], grav[t >= T0 + 210], [f for f in fixes if f[0] >= T0 + 210],
           rr=rr[t >= T0 + 210])
    assert _axis_cos(p, fwd) > 0.99


def test_gyro_bias_over_a_long_stop_and_a_slow_parking_turn_are_not_a_remount():
    rng = np.random.default_rng(4)
    # 5 minutes standing with 0.005 rad/s of bias and 0.02 rad/s of noise (17° of drift in all), then
    # a parking turn of 90° at 0.08 rad/s: neither is faster than FWD_REMOUNT_RATE.
    def yaw(rel):
        w = 0.005 + 0.02 * rng.standard_normal(len(rel))
        return w + np.where((rel >= 300) & (rel < 300 + math.pi / 2 / 0.08), 0.08, 0.0)
    t, ua, grav, fixes, rr, fwd = _stop_and_go(brake_at=120, stop_s=240.0, yaw_rate=yaw, seconds=560)
    p = dsp.Pipeline()
    p.feed(t, ua, grav, fixes, rr=rr)
    assert p.forward_n > 200 and _axis_cos(p, fwd) > 0.99  # never restarted


def test_a_trip_saved_before_the_remount_checks_carries_on():
    old = {k: v for k, v in dsp.Pipeline(_forward_known_state()).to_state().items()
           if k not in ("still_yaw", "fwd_settle_until", "g_ema", "g_ref")}
    p = dsp.Pipeline(json.loads(json.dumps(old)))
    assert p.forward_known and p.still_yaw == 0.0 and p.g_ref is None


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
        assert a.rough_rms == pytest.approx(b.rough_rms, rel=1e-6, abs=1e-9)
        assert a.dose_inc == pytest.approx(b.dose_inc, rel=1e-6, abs=1e-12)
        assert (a.speed is None) == (b.speed is None)
    assert [(round(e.t, 6), e.type) for e in events] == [(round(e.t, 6), e.type) for e in whole.events]
    assert len(events) == 2
    assert last.msdv == pytest.approx(whole.msdv, rel=1e-6)
    assert last.roughness_now == pytest.approx(whole.roughness_now, rel=1e-6)


def _vertical_only(rel, vert):
    r = _phone_frame()
    ua = (np.column_stack([0 * rel, 0 * rel, vert]) @ r.T) / dsp.G
    return T0 + rel, ua, np.tile(np.array([0, 0, -1.0]) @ r.T, (len(rel), 1))


@pytest.mark.parametrize("rate", [99.5, 100.5])
def test_resampling_keeps_high_frequencies_wherever_the_samples_fall(rate):
    """A phone a little off 100 Hz drifts through every sub-sample phase against the grid. Linear
    interpolation left a 20 Hz sine 0.81–0.97 of its RMS and 28 Hz 0.55–0.84, window by window."""
    for f0, low in ((20.0, 0.98), (28.0, 0.80)):
        rel = np.arange(int(20 * rate)) / rate
        out, _ = run_whole(*_vertical_only(rel, math.sqrt(2) * np.sin(2 * np.pi * f0 * rel)), [])
        rms = [p.rough_rms for p in out.series[10:]]
        assert min(rms) > low, f0
        assert max(rms) < 1.01, f0


def test_a_jolt_between_samples_keeps_its_peak():
    """A 10 ms jolt just above the pothole threshold: with the samples off the grid by up to 9 ms,
    linear interpolation cut its band-passed peak by 12 % and 9 of 10 were missed."""
    peaks = []
    for off in np.linspace(0, 0.009, 10):
        rel = np.arange(1000) / 100.0 + off
        rel[0] = 0.0  # keeps the grid's origin, so only the samples move
        t, ua, grav = _vertical_only(rel, _pulse(5.0, 8.0, 0.01)(rel))
        p = dsp.Pipeline()
        out = p.feed(t, ua, grav, [(T0 + s + 0.3, 10.0) for s in range(10)])
        peaks.append(max(abs(s.a_vert) for s in out.series))
        assert [e.type for e in out.events + p.flush()] == ["pothole"], off
    assert min(peaks) > 0.98 * peaks[0]


def test_bunched_samples_fall_back_to_linear_interpolation():
    """Two samples 0.5 ms apart would make the Lagrange weights huge; the stencil falls back to
    linear and the output stays as small as the input."""
    rel = np.arange(600) / 100.0
    vert = 0.5 * np.sin(2 * np.pi * 3 * rel)
    rel = np.insert(rel, 300, rel[300] + 0.0005)
    vert = np.insert(vert, 300, vert[300] + 0.3)  # a little noise on the bunched sample
    out, _ = run_whole(*_vertical_only(rel, vert), [])
    assert max(abs(s.a_vert) for s in out.series) < 1.5


def test_a_trip_saved_by_the_linear_resampler_continues(monkeypatch):
    """A trip in progress during the deploy has a grid without `hist`/`n_seen`, saved after every grid
    point up to its last sample: it continues from that sample, starting linear, without a reset."""
    t, ua, grav, fixes = synth(40, vert=lambda t: 0.5 * np.sin(2 * np.pi * 0.3 * t)
                               + np.sin(2 * np.pi * 4 * t))
    cut = len(t) // 2
    first = [f for f in fixes if f[0] < t[cut]]
    rest = [f for f in fixes if f[0] >= t[cut]]
    whole, _ = run_whole(t, ua, grav, fixes)

    with monkeypatch.context() as m:
        m.setattr(dsp, "INTERP_HALF", 1)  # linear, and nothing waits for later samples: the old resampler
        p = dsp.Pipeline()
        p.feed(t[:cut], ua[:cut], grav[:cut], first)
    old = json.loads(json.dumps(p.to_state()))
    del old["grid"]["hist"], old["grid"]["n_seen"]

    out = dsp.Pipeline(old).feed(t[cut:], ua[cut:], grav[cut:], rest)
    assert not out.reset
    tail = [s for s in whole.series if s.t > t[cut] + 1.0]
    got = {round(s.t, 6): s for s in out.series}
    assert all(round(s.t, 6) in got for s in tail)
    assert max(abs(got[round(s.t, 6)].a_vert - s.a_vert) for s in tail) < 0.02
    assert out.msdv == pytest.approx(whole.msdv, rel=0.01)


def test_overlapping_batches_are_not_interleaved():
    """A batch that starts 25 ms before the previous one ended (clock re-anchoring) must not feed
    out-of-order times to the interpolation: no false events, same roughness as aligned batches."""
    # 3 Hz: well inside the band, and slow enough that the half-sample shift below costs no amplitude
    # in linear interpolation (at 10 Hz it would lose ≈ 4 %, which is interpolation, not the overlap).
    amp = 2.0
    t, ua, grav, fixes = synth(20, vert=lambda t: amp * np.sin(2 * np.pi * 3 * t), jitter=False)
    half = len(t) // 2
    aligned = dsp.Pipeline()
    aligned.feed(t[:half], ua[:half], grav[:half], [f for f in fixes if f[0] < t[half]])
    ref = aligned.feed(t[half:], ua[half:], grav[half:], [f for f in fixes if f[0] >= t[half]])

    p = dsp.Pipeline()
    first = p.feed(t[:half], ua[:half], grav[:half], [f for f in fixes if f[0] < t[half]])
    back = half - 3  # the second batch repeats the last 3 samples with times shifted 5 ms earlier
    out = p.feed(t[back:] - 0.005, ua[back:], grav[back:], [f for f in fixes if f[0] >= t[half]])

    assert not out.reset and out.events == [] and first.events == []
    times = [s.t for s in first.series + out.series]
    assert all(b > a for a, b in zip(times, times[1:]))
    assert out.roughness_now == pytest.approx(ref.roughness_now, rel=0.02)


def test_clock_jumping_back_resets():
    t, ua, grav, fixes = synth(4)
    p = dsp.Pipeline()
    p.feed(t, ua, grav, fixes)
    out = p.feed(t - 2.0, ua, grav, [])
    assert out.reset


def test_window_sums_add_up_to_the_trip():
    """The per-window outputs the finalize job builds segment passes from must agree with the trip
    totals: Σ dose_inc = MSDV², and a 10 Hz sine's window RMS is its RMS."""
    amp = 3.0
    t, ua, grav, fixes = synth(60, vert=lambda t: amp * np.sin(2 * np.pi * 10 * t) + np.sin(0.9 * t))
    out, _ = run_whole(t, ua, grav, fixes)
    assert sum(p.dose_inc for p in out.series) == pytest.approx(out.msdv ** 2, rel=0.01)
    steady = [p.rough_rms for p in out.series if p.t > T0 + 5]
    assert np.median(steady) == pytest.approx(amp / math.sqrt(2), rel=0.05)


def test_state_is_json():
    t, ua, grav, fixes = synth(5)
    p = dsp.Pipeline()
    p.feed(t, ua, grav, fixes)
    assert json.loads(json.dumps(p.to_state())) == p.to_state()


# --- Speed bumps ----------------------------------------------------------------------------

def _pulse(at, amp, width=0.08):
    return lambda t: amp * np.exp(-((t - at) / width) ** 2)


def synth_bumps(seconds, bumps, *, speed=15 / 3.6 + 0.2, wheelbase=2.7, rate_amp=0.4, vert_amp=15.0,
                extra_vert=None, seed=2):
    """synth() plus a rotation rate: each bump at time b pitches the nose up (front axle climbing) and,
    one wheelbase later, down (rear axle), with a vertical jolt at both axles."""
    t, ua, grav, fixes = synth(seconds, speed=lambda t: 0 * t + speed, seed=seed)
    rel = t - T0
    pitch_up = np.zeros_like(rel)
    vert = np.zeros_like(rel) if extra_vert is None else extra_vert(rel)
    for b in bumps:
        rear = b + wheelbase / speed
        pitch_up += _pulse(b, rate_amp)(rel) - _pulse(rear, rate_amp)(rel)
        vert += _pulse(b, vert_amp, 0.01)(rel) + _pulse(rear, vert_amp, 0.01)(rel)
    r = _phone_frame()
    ua = ua + dsp.UA_SIGN * (np.column_stack([0 * rel, 0 * rel, vert]) @ r.T) / dsp.G
    # Nose up is a negative rotation about the vehicle's left (+y) axis.
    rr = np.column_stack([0 * rel, -pitch_up, 0 * rel]) @ r.T
    return t, ua, grav, fixes, rr


def _forward_known_state():
    fwd = _phone_frame() @ np.array([1.0, 0.0, 0.0])
    return {"forward_sum": (fwd * dsp.FWD_MIN_EVIDENCE * 2).tolist(), "forward_n": dsp.FWD_MIN_EVIDENCE * 2}


def _feed_bumps(t, ua, grav, fixes, rr, state=None):
    p = dsp.Pipeline(state if state is not None else _forward_known_state())
    out = p.feed(t, ua, grav, fixes, rr=rr)
    return out, p


def test_pitch_rate_sign_and_axis():
    p = dsp.Pipeline(_forward_known_state())
    r = _phone_frame()
    down = np.tile(np.array([0, 0, -1.0]) @ r.T, (3, 1))
    rr = np.array([[0, -0.3, 0], [0.3, 0, 0], [0, 0, 0.3]]) @ r.T  # nose up, roll, yaw
    assert p._pitch_up(down, rr) == pytest.approx([0.3, 0.0, 0.0], abs=1e-9)
    assert dsp.Pipeline()._pitch_up(down, rr) == pytest.approx([0, 0, 0])  # forward axis unknown


def test_speed_bump_detected_and_its_jolts_are_not_potholes():
    t, ua, grav, fixes, rr = synth_bumps(12, [5.0])
    out, _ = _feed_bumps(t, ua, grav, fixes, rr)
    (ev,) = out.events
    assert ev.type == "speed_bump" and abs(ev.t - (T0 + 5.0)) < 0.1
    assert ev.magnitude > dsp.POTHOLE_THRESHOLD_MS2 and 0 < ev.confidence <= 1
    assert ev.speed == pytest.approx(15 / 3.6 + 0.2)


def test_speed_bumps_found_with_a_learned_forward_axis():
    """As on a real trip: no preset axis. 3 min of speed changes teach it, then 4 bumps at 15 km/h.
    With the raw CoreMotion sign the axis came out backwards and all 4 were reported as potholes."""
    secs, learn_s, v = 230, 180, 15 / 3.6 + 0.2
    lon = lambda t: np.where(t < learn_s, 4 * 2 * np.pi / 20 * np.cos(2 * np.pi * t / 20), 0.0)  # noqa: E731
    speed = lambda t: np.where(t < learn_s, 8 + 4 * np.sin(2 * np.pi * t / 20), v)  # noqa: E731
    t, ua, grav, fixes = synth(secs, lon=lon, speed=speed, seed=5)
    rel = t - T0
    bumps = [190.0, 200.0, 210.0, 220.0]
    pitch_up, vert = np.zeros_like(rel), np.zeros_like(rel)
    for b in bumps:
        rear = b + 2.7 / v
        pitch_up += _pulse(b, 0.4)(rel) - _pulse(rear, 0.4)(rel)
        vert += _pulse(b, 15.0, 0.01)(rel) + _pulse(rear, 15.0, 0.01)(rel)
    r = _phone_frame()
    ua = ua + dsp.UA_SIGN * (np.column_stack([0 * rel, 0 * rel, vert]) @ r.T) / dsp.G
    rr = np.column_stack([0 * rel, -pitch_up, 0 * rel]) @ r.T
    p = dsp.Pipeline()
    out = p.feed(t, ua, grav, fixes, rr=rr)
    events = out.events + p.flush()
    assert [round(e.t - T0) for e in events if e.type == "speed_bump"] == bumps
    assert not [e for e in events if e.type == "pothole"]
    # a_vert is positive upwards: the jolt of the front axle climbing the bump.
    jolt = max((s for s in out.series if abs(s.t - T0 - bumps[0]) < 0.3), key=lambda s: abs(s.a_vert))
    assert jolt.a_vert > dsp.POTHOLE_THRESHOLD_MS2


@pytest.mark.parametrize("wheelbase", [2.2, 3.0, 6.0])
def test_speed_bump_for_car_and_bus_wheelbases(wheelbase):
    t, ua, grav, fixes, rr = synth_bumps(14, [5.0], speed=6.0, wheelbase=wheelbase)
    out, _ = _feed_bumps(t, ua, grav, fixes, rr)
    assert [e.type for e in out.events] == ["speed_bump"]


def test_no_speed_bump_without_the_forward_axis():
    t, ua, grav, fixes, rr = synth_bumps(12, [5.0])
    out, _ = _feed_bumps(t, ua, grav, fixes, rr, state={})
    # As before speed bumps existed: the jolts are potholes (one, since the second is within 1 s).
    assert [e.type for e in out.events] == ["pothole"]


def test_peaks_too_far_apart_for_an_axle_pair_are_not_a_bump():
    t, ua, grav, fixes, rr = synth_bumps(14, [5.0], wheelbase=15.0)
    out, _ = _feed_bumps(t, ua, grav, fixes, rr)
    assert [e.type for e in out.events] == ["pothole", "pothole"]


def test_no_speed_bump_when_fast_or_from_one_pitch_peak():
    t, ua, grav, fixes, rr = synth_bumps(12, [5.0], speed=60 / 3.6, vert_amp=0.0)
    assert _feed_bumps(t, ua, grav, fixes, rr)[0].events == []
    t, ua, grav, fixes, _ = synth_bumps(12, [], vert_amp=0.0)
    rr = np.column_stack([0 * t, -_pulse(5.0, 0.4)(t - T0), 0 * t]) @ _phone_frame().T  # a crest
    assert _feed_bumps(t, ua, grav, fixes, rr)[0].events == []


def _pitch_only(t, pitch_up):
    """Rotation rate for a nose-up pitch rate pitch_up(rel t)."""
    rel = t - T0
    return np.column_stack([0 * rel, -pitch_up(rel), 0 * rel]) @ _phone_frame().T


@pytest.mark.parametrize("at", np.round(np.arange(5.0, 6.0, 0.05), 2))
def test_speed_bump_found_whenever_a_fix_lands_in_its_front_peak(at):
    # Fixes at s + 0.3: for some bump times one is taken between the front peak's extreme and its
    # end, and the speed was then looked up too late (None), dropping the front axle.
    t, ua, grav, fixes, rr = synth_bumps(12, [at])
    out, p = _feed_bumps(t, ua, grav, fixes, rr)
    assert [e.type for e in out.events + p.flush()] == ["speed_bump"]


def test_pothole_just_before_a_slow_speed_bump_is_not_released_early():
    """A bus (5 m wheelbase) braking into a bump: the jolt 0.45 s before the front axle is taken at
    the old fix's 4.3 m/s, the bump at 2.5 m/s, so its rear axle comes 2 s later. The bump covers the
    jolt, but a fixed 2.5 s hold had already reported it as a pothole."""
    front, wheelbase, v = 6.0, 5.0, 2.5
    rear = front + wheelbase / v
    jolts = lambda rel: (_pulse(front - 0.45, 15.0, 0.01)(rel) + _pulse(front, 15.0, 0.01)(rel)  # noqa: E731
                         + _pulse(rear, 15.0, 0.01)(rel))
    t, ua, grav, _ = synth(12, vert=jolts)
    fixes = [(T0 + s + 0.3, 4.3) for s in range(5)] + [(T0 + s + 0.9, v) for s in range(5, 11)]
    rr = _pitch_only(t, lambda rel: _pulse(front, 0.4)(rel) - _pulse(rear, 0.4)(rel))
    out, p = _feed_bumps(t, ua, grav, fixes, rr)
    assert [(e.type, round(e.t - T0, 1)) for e in out.events + p.flush()] == [("speed_bump", front)]


@pytest.mark.parametrize("speed", [6.0, 8.0, 10.0])
@pytest.mark.parametrize("hz,zeta", [(1.0, 0.3), (1.3, 0.3), (1.5, 0.2), (1.5, 0.4)])
def test_a_single_impact_ringing_in_pitch_is_a_pothole_not_a_speed_bump(speed, hz, zeta):
    # One jolt that sets the body pitching: its rebound has the sign and timing of a rear axle, but no
    # rear-axle jolt of its own.
    wd = 2 * np.pi * hz * np.sqrt(1 - zeta ** 2)

    def ring(rel):
        tt = np.clip(rel - 5.0, 0, None)
        return np.where(rel >= 5.0, 0.4 * np.exp(-zeta * 2 * np.pi * hz * tt) * np.sin(wd * tt), 0.0)

    t, ua, grav, fixes = synth(12, vert=_pulse(5.0, 12.0, 0.01), speed=lambda t: 0 * t + speed)
    out, p = _feed_bumps(t, ua, grav, fixes, _pitch_only(t, ring))
    assert [e.type for e in out.events + p.flush()] == ["pothole"]


def test_a_trip_saved_mid_bump_by_the_previous_version_continues():
    """Front peaks saved without their speed, front axles without their jolt, no recent-jolt list."""
    t, ua, grav, fixes, rr = synth_bumps(12, [5.0])
    whole, p = _feed_bumps(t, ua, grav, fixes, rr)
    cut = int(np.searchsorted(t, T0 + 5.5))  # between the two axles: the front one is pending
    first, q = _feed_bumps(t[:cut], ua[:cut], grav[:cut], [f for f in fixes if f[0] < t[cut]], rr[:cut])
    old = json.loads(json.dumps(q.to_state()))
    bump = old["grid"]["bump"]
    assert bump["p1"] is not None
    bump["p1"] = bump["p1"][:4]
    bump.pop("recent")
    if bump["peak"] is not None:
        bump["peak"] = bump["peak"][:5]
    q = dsp.Pipeline(old)
    rest = q.feed(t[cut:], ua[cut:], grav[cut:], [f for f in fixes if f[0] >= t[cut]], rr=rr[cut:])
    assert [e.type for e in first.events + rest.events + q.flush()] == ["speed_bump"]


def test_potholes_are_held_back_and_flushed_at_the_end():
    t, ua, grav, fixes = synth(10, vert=_spike(9.6), speed=lambda t: 0 * t + 10.0)
    out, p = run_whole(t, ua, grav, fixes)
    assert out.events == []  # a front peak could still start within BUMP_SPAN_PAD_S of it
    (ev,) = p.flush()
    assert ev.type == "pothole" and abs(ev.t - (T0 + 9.6)) < 0.05
    assert p.flush() == [] and p.to_state()["held"] == []


def test_speed_bumps_chunked_equal_one_pass():
    rng = np.random.default_rng(4)
    noise = rng.normal(0, 0.3, 200 * 100 + 10)
    extra = lambda rel: noise[np.clip((rel * 100).astype(int), 0, len(noise) - 1)] + _spike(150.0)(rel)  # noqa: E731
    t, ua, grav, fixes, rr = synth_bumps(200, [20.0, 61.3, 120.7, 181.0], speed=5.5, extra_vert=extra)
    whole, p = _feed_bumps(t, ua, grav, fixes, rr)
    whole_events = whole.events + p.flush()

    rng = np.random.default_rng(9)
    events, state, start = [], _forward_known_state(), t[0]
    while start <= t[-1]:
        end = start + rng.uniform(1.0, 3.0)
        m = (t >= start) & (t < end)
        q = dsp.Pipeline(json.loads(json.dumps(state)))
        events += q.feed(t[m], ua[m], grav[m], [x for x in fixes if start <= x[0] < end], rr=rr[m]).events
        state = q.to_state()
        start = end
    events += dsp.Pipeline(state).flush()

    key = lambda es: [(e.type, round(e.t, 6), e.magnitude) for e in es]  # noqa: E731
    assert key(events) == key(whole_events)
    assert [e.type for e in whole_events].count("speed_bump") == 4
    assert [e.type for e in whole_events].count("pothole") == 1


def test_a_trip_saved_before_rotation_rate_continues():
    """State written by the previous version (no rotation channel, pitch filter, held potholes)."""
    t, ua, grav, fixes = synth(8, vert=_spike(6.0), speed=lambda t: 0 * t + 10.0)
    half = len(t) // 2
    p = dsp.Pipeline()
    p.feed(t[:half], ua[:half], grav[:half], [f for f in fixes if f[0] < t[half]])
    old = json.loads(json.dumps(p.to_state()))
    for k in ("held", "last_bump_t"):
        old.pop(k)
    for k in ("zi_pitch", "bump"):
        old["grid"].pop(k)
    old["grid"]["prev"] = old["grid"]["prev"][:7]
    q = dsp.Pipeline(old)
    out = q.feed(t[half:], ua[half:], grav[half:], [f for f in fixes if f[0] >= t[half]])
    assert not out.reset and [e.type for e in out.events + q.flush()] == ["pothole"]


# --- Resets ---------------------------------------------------------------------------------

def test_a_reset_does_not_inject_dose_from_its_first_sample():
    """User acceleration is zero-mean: starting the 2 Hz low-pass as if the first sample had lasted
    forever released a step into Wf (x0 = 2 m/s² gave 0.096 m²/s³ of dose from nothing)."""
    vert = lambda t: np.where(np.arange(len(t)) == 0, 2.0, 0.0)  # noqa: E731
    t, ua, grav, fixes = synth(60, vert=vert, jitter=False)
    out, p = run_whole(t, ua, grav, fixes)
    assert p.dose < 0.001


def test_window_dose_adds_up_to_the_trip_across_resets():
    """A reset cut the open 5 Hz window and dropped its dose, so Σ dose_inc < dose (and passes' a_w
    came out low). The cut-short dose now goes into the next window."""
    vert = lambda t: np.sin(2 * np.pi * 0.2 * t)  # noqa: E731
    t, ua, grav, fixes = synth(60, vert=vert)
    m = ~(((t >= T0 + 20.03) & (t < T0 + 20.6)) | ((t >= T0 + 41.11) & (t < T0 + 41.7)))
    out, p = run_whole(t[m], ua[m], grav[m], fixes)
    assert out.reset

    def open_dose(pipe):  # the window still open at the end of the data, not emitted yet
        return pipe.grid["win"]["aw2"] + pipe.carry_aw2

    assert sum(pt.dose_inc for pt in out.series) + open_dose(p) == pytest.approx(p.dose, rel=1e-9)
    # Also when the reset comes between feeds (a missing batch).
    q = dsp.Pipeline()
    half = int(np.searchsorted(t, T0 + 30.07))
    a = q.feed(t[:half], ua[:half], grav[:half], [f for f in fixes if f[0] < t[half]])
    b = q.feed(t[half:], ua[half:], grav[half:], [f for f in fixes if f[0] >= t[half]], reset=True)
    assert sum(pt.dose_inc for pt in a.series + b.series) + open_dose(q) == pytest.approx(q.dose, rel=1e-9)


def test_no_pothole_at_exactly_15_kmh():
    """Plan §9 step 5 and the pass ratio: above 15 km/h, not at it."""
    out_at, _ = run_whole(*synth(10, vert=_spike(5.0), speed=lambda t: 0 * t + dsp.POTHOLE_MIN_SPEED_MS))
    assert not [e for e in out_at.events if e.type == "pothole"]
    out_above, _ = run_whole(*synth(10, vert=_spike(5.0), speed=lambda t: 0 * t + dsp.POTHOLE_MIN_SPEED_MS + 0.1))
    assert [e.type for e in out_above.events] == ["pothole"]
