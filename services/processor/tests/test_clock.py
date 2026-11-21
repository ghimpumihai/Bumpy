"""A wall-clock step mid-trip (clock.py): batches built as the app builds them, drained by arrival
every 2 s with the UTC offset of the latest clock anchor (every 10 s), while the fixes carry the wall
clock, which steps at STEP_AT."""

import dataclasses
import datetime as dt

import numpy as np
import pytest
from conftest import requires_db

from roadride import clock
from roadride import finalize as fz
from roadride.live import parse_batch

UP0 = 5000.0
UTC0_MS = 1_795_000_000_000.0
STEP_AT = UP0 + 61.0
POTHOLES = (41.37, 87.9)
UTC = dt.timezone.utc


def _wall_ms(up, step_ms):
    up = np.asarray(up, dtype=float)
    return UTC0_MS + (up - UP0) * 1000 + np.where(up >= STEP_AT, step_ms, 0.0)


def phone_batches(step_ms=0.0, seconds=120, fix_latency=0.1, sid="S", device="D", seq0=0):
    rng = np.random.default_rng(3)
    n = seconds * 100
    t_up = UP0 + np.sort(np.arange(n) / 100 + rng.uniform(-0.002, 0.002, n))
    rel = t_up - UP0
    vert = 0.6 * np.sin(2 * np.pi * 0.18 * rel) + rng.normal(0, 0.4, n)
    for p in POTHOLES:
        vert += 14 * np.exp(-((rel - p) / 0.012) ** 2)
    fix_t = UP0 + np.arange(seconds) + 0.3
    fix_v = np.array([6 + 1.5 * (s % 20 if s % 20 < 10 else 20 - s % 20) for s in range(seconds)])
    anchors = UP0 + np.arange(0, seconds + 12, 10.0)

    def utc_now(up, at):  # the app's TimeBase: the latest anchor at drain time `at`
        a = anchors[anchors <= at][-1]
        return float(_wall_ms(a, step_ms)) + (up - a) * 1000

    out, start = [], UP0
    for k in range(seconds // 2 + 1):
        end = start + 2.0
        m = (t_up >= start) & (t_up < end)
        f = (fix_t + fix_latency >= start) & (fix_t + fix_latency < end)
        z = [0.0] * int(m.sum())
        out.append(parse_batch({
            "sessionId": sid, "deviceId": device, "batchSeq": seq0 + k, "t0Up": round(start, 6),
            "t0UtcMs": int(round(utc_now(start, end))), "t0Utc": "", "source": "live",
            "deviceMotion": {"t": [round(x - start, 6) for x in t_up[m]], "ua_x": z, "ua_y": z,
                             "ua_z": list(vert[m] / 9.80665), "g_x": z, "g_y": z, "g_z": [-1.0] * len(z),
                             "rr_x": z, "rr_y": z, "rr_z": z},
            "accelRaw": {"t": []}, "gyroRaw": {"t": []}, "altimeter": {"t": []}, "audioLevel": {"t": []},
            "location": [{"tUtcMs": int(round(float(_wall_ms(ft, step_ms)))), "lat": 46.77 + i * 1e-4,
                          "lon": 23.6, "speed": float(v), "course": 0.0, "hAcc": 5.0}
                         for i, (ft, v) in enumerate(zip(fix_t[f], fix_v[f]))],
            "labels": [], "device": {"battery": 0.5, "thermal": "nominal", "lowPower": False}}))
        start = end
    return out


def _speeds(sig):
    return [p.speed for p in sig.series]


def _live(batches):
    """The stream processor's view: no hindsight, each batch with the trip clock and the clamp."""
    tc, out = clock.TripClock(), []
    for f in batches:
        out.append(dataclasses.replace(f, clock_offset=tc.offset(f.clock_offset), fixes=[
            dataclasses.replace(x, t_up=clock.fix_uptime(f, x)) for x in f.fixes]))
    return out


BASE = None


def _base():
    global BASE
    if BASE is None:
        BASE = fz.run_pipeline(phone_batches())
    return BASE


def test_a_trip_without_a_step_is_unchanged():
    batches = phone_batches()
    norm = clock.normalize(batches)
    assert [dataclasses.replace(f, fixes=[dataclasses.replace(x, t_up=None) for x in f.fixes]) for f in norm] == batches
    assert [x.t_up for f in norm for x in f.fixes] == [x.t.timestamp() - f.clock_offset for f in batches for x in f.fixes]


@pytest.mark.parametrize("step_ms", [1500.0, -1500.0, 400.0, -400.0, 3_600_000.0])
def test_finalize_places_fixes_across_a_step(step_ms):
    """Before: +1.5 s gave 37 windows with another speed, -1.5 s 26 and a series running back 1.3 s,
    +1 h 35 (25 of them without a speed)."""
    sig = fz.run_pipeline(clock.normalize(phone_batches(step_ms)))
    assert _speeds(sig) == _speeds(_base())
    t = np.array([p.t for p in sig.series])
    assert (np.diff(t) > 0).all()
    shift = max(step_ms, 0.0) / 1000  # forward: the times jump with the phone's; backward: absorbed
    base_t = [e.t for e in _base().events]
    assert [e.t for e in sig.events] == pytest.approx(
        [b + (shift if b - UTC0_MS / 1000 > STEP_AT - UP0 else 0.0) for b in base_t], abs=1e-6)


@pytest.mark.parametrize("step_ms", [-1500.0, 3_600_000.0])
def test_live_times_never_run_back_and_a_large_step_keeps_its_speeds(step_ms):
    """Without hindsight a fix can still be a batch window off until the finalize job, but a large step
    no longer puts it an hour away (25 windows without a speed before)."""
    sig = fz.run_pipeline(_live(phone_batches(step_ms)))
    assert (np.diff([p.t for p in sig.series]) > 0).all()
    assert sum(s is None for s in _speeds(sig)) == sum(s is None for s in _speeds(_base()))


def test_trip_clock_absorbs_a_backward_step_until_a_forward_one_gives_it_back():
    tc = clock.TripClock()
    # ms jitter is followed; -1.5 s is absorbed; +1.5 s gives it back; +3 s is followed.
    assert [round(tc.offset(x), 4) for x in (100.0, 100.0005, 98.5, 98.5, 100.0, 103.0)] == \
        [100.0, 100.0005, 100.0005, 100.0005, 100.0005, 103.0]
    assert clock.TripClock.from_state(tc.to_state()) == tc


# --- The stream processor --------------------------------------------------------------------

def _apply(db, batches, received):
    from roadride.store import Store

    s = Store(db)
    for f, r in zip(batches, received):
        with db.transaction():
            s.apply_batch(f, r)


@requires_db
def test_live_series_never_runs_back_after_a_backward_step(db):
    batches = phone_batches(-1500.0)
    recv = [dt.datetime(2026, 11, 21, 9, 0, tzinfo=UTC) + dt.timedelta(seconds=2 * k) for k in range(len(batches))]
    _apply(db, batches, recv)
    t = [r[0] for r in db.execute("SELECT t FROM session_series ORDER BY t").fetchall()]
    msdv = [r[0] for r in db.execute("SELECT msdv FROM session_series ORDER BY t").fetchall()]
    assert len(t) == len(_base().series) and msdv == sorted(msdv)  # time order is the pipeline's order


@requires_db
def test_live_state_follows_the_device_through_a_backward_step_and_into_its_next_trip(db):
    """Before: guarded by the phone's clock, a step back of 5 s froze the device until the clock
    caught up, and carried the freeze into its next trip."""
    first = phone_batches(seconds=20)
    back = [dataclasses.replace(f, end_utc=f.end_utc - dt.timedelta(seconds=5)) for f in first[5:]]
    nxt = [dataclasses.replace(f, session_id="S2", end_utc=f.end_utc - dt.timedelta(seconds=5))
           for f in phone_batches(seconds=4, sid="S2")]
    batches = first[:5] + back + nxt
    recv = [dt.datetime(2026, 11, 21, 9, 0, tzinfo=UTC) + dt.timedelta(seconds=2 * k) for k in range(len(batches))]
    _apply(db, batches[:-1], recv[:-1])
    assert db.execute("SELECT received_at FROM live_state").fetchone()[0] == recv[-2]
    _apply(db, batches[-1:], recv[-1:])
    assert db.execute("SELECT session_id, received_at FROM live_state").fetchone() == ("S2", recv[-1])
