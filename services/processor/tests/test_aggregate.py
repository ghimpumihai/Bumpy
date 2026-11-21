"""The aggregation method (port of dashboard/src/mock/aggregate.ts): β and vehicle effects recovered
by the fixed-effects fit, the percentile fallback, crowd-confirmed potholes, sickness not normalized."""

import math

import numpy as np
import pytest

from roadride import aggregate as agg


def _obs(sid, cell, vehicle, speed, rough, *, potholes=0, aw=0.3, dur=2.0, ok=True, seat="front",
         posture="seated", sick_s=None, sick_aw=None):
    return agg.Obs(session_id=sid, h3=cell, vehicle=vehicle, duration_s=dur, speed=speed, roughness=rough,
                   aw_rms=aw, pothole_count=potholes, roughness_eligible=ok, sickness_eligible=ok,
                   rater_seat=seat, rater_posture=posture, sickness_s=sick_s, sickness_aw_rms=sick_aw)


def _world(beta=0.6, bus=0.4, n_cells=40, seed=2):
    """Cars and buses over the same cells at different speeds: log r = cell + vehicle + β·log(v/10)."""
    rng = np.random.default_rng(seed)
    cells = {f"8b1f{i:011x}": rng.normal(0.0, 0.5) for i in range(n_cells)}
    rows = []
    for s in range(6):
        vehicle = "bus" if s % 2 else "car"
        for cell, effect in cells.items():
            v = rng.uniform(5, 18)
            r = math.exp(effect + (bus if vehicle == "bus" else 0.0) + beta * math.log(v / 10) + rng.normal(0, 0.05))
            rows.append(_obs(f"s{s}", cell, vehicle, v, r))
    return rows


def test_fit_recovers_beta_and_vehicle_effect():
    result = agg.compute(_world())
    assert result.method == "model"
    assert result.fit.beta == pytest.approx(0.6, abs=0.05)
    assert result.fit.effects["car"] == 0.0
    assert result.fit.effects["bus"] == pytest.approx(0.4, abs=0.05)
    # Normalized roughness is what a car feels at 10 m/s: the cell effect itself.
    rows = [a for a in result.aggs if a["vehicle_type"] == "all"]
    assert len(rows) == 40 and all(a["roughness_method"] == "model" and a["roughness"] > 0 for a in rows)


def test_a_vehicle_the_fit_cant_identify_doesnt_switch_the_model_off():
    """A vehicle type that never shares a multi-pass segment with the others (a lone bike, or
    `unknown` from a session.json without a vehicle type) has no identifiable effect. It is left out
    of the fit, which stays the same for the others; its cells get no car-equivalent roughness."""
    base = agg.compute(_world())
    lone = [_obs("bike1", f"b{i}", "bike", 8, 2.0) for i in range(3)]  # single-pass cells
    lone += [_obs("unk1", "u1", "unknown", 8, 2.0), _obs("unk1", "u1", "unknown", 12, 2.5)]  # its own loop
    result = agg.compute(_world() + lone)
    assert result.method == "model"
    assert result.fit.beta == pytest.approx(base.fit.beta, abs=1e-12)
    assert result.fit.effects == pytest.approx(base.fit.effects, abs=1e-12)
    assert "bike" not in result.fit.effects and "unknown" not in result.fit.effects
    u1 = next(a for a in result.aggs if a["h3"] == "u1" and a["vehicle_type"] == "all")
    assert u1["roughness"] is None and u1["roughness_method"] == "percentile" and u1["roughness_pctl"] is not None


def test_without_cars_overlapping_there_is_no_car_equivalent():
    # Buses and trams only: their effects relative to a car are undefined, so the fallback stays.
    rows = [_obs(o.session_id, o.h3, "tram" if o.vehicle == "car" else o.vehicle, o.speed, o.roughness)
            for o in _world()]
    result = agg.compute(rows)
    assert result.method == "percentile" and result.fit is None


def test_sickness_counts_moving_valid_time_only():
    """Plan §10: bus stops and idling are separated using speed near zero. A bus standing 300 s at a
    stop used to pull the cell from 0.40 to 0.12 m/s²."""
    rows = [_obs(f"car{i}", "c1", "car", 10, 1.0, aw=0.40, dur=3.0, sick_s=3.0, sick_aw=0.40) for i in range(9)]
    rows.append(_obs("bus1", "c1", "bus", 0.0, None, aw=0.03, dur=300.0, sick_s=0.0, sick_aw=None))
    result = agg.compute(rows)
    every = next(a for a in result.aggs if a["vehicle_type"] == "all")
    assert every["sickness_aw_rms"] == pytest.approx(0.40)
    assert every["msi_1h_pct"] == pytest.approx(0.40 * 60 / 3)
    assert every["sickness_sessions"] == 9  # the standing bus contributed no moving time
    bus = next(a for a in result.aggs if a["vehicle_type"] == "bus")
    assert bus["sickness_aw_rms"] is None and bus["msi_1h_pct"] is None and bus["sickness_sessions"] == 0
    assert {s["vehicle_type"] for s in result.sickness} == {"car"}


def test_too_little_overlap_falls_back_to_percentiles():
    rows = [_obs("a", "c1", "car", 10, 1.0), _obs("a", "c2", "car", 10, 2.0), _obs("b", "c1", "bus", 10, 1.5)]
    result = agg.compute(rows)
    assert result.method == "percentile" and result.fit is None
    c2 = next(a for a in result.aggs if a["h3"] == "c2" and a["vehicle_type"] == "all")
    assert c2["roughness"] is None and c2["roughness_pctl"] == 1.0  # roughest cell of session a


def test_slow_and_ineligible_passes_dont_count_for_roughness():
    rows = [_obs("a", "c1", "car", 1.0, 1.0), _obs("b", "c1", "car", 10, 1.0, ok=False)]
    (all_row,) = [a for a in agg.compute(rows).aggs if a["vehicle_type"] == "all"]
    assert all_row["roughness_method"] == "none" and all_row["n_passes"] == 2


def test_potholes_are_crowd_confirmed_per_vehicle_type():
    rows = [_obs("a", "c1", "car", 10, 1.0, potholes=1), _obs("b", "c1", "car", 10, 1.0, potholes=1),
            _obs("c", "c1", "car", 10, 1.0), _obs("d", "c1", "car", 3, 1.0, potholes=1),  # too slow
            _obs("e", "c1", "tram", 10, 1.0, potholes=1), _obs("f", "c1", "tram", 10, 1.0)]
    by = {a["vehicle_type"]: a for a in agg.compute(rows).aggs}
    assert (by["car"]["pothole_hits"], by["car"]["pothole_passes"], by["car"]["pothole_confirmed"]) == (2, 3, True)
    assert by["tram"]["pothole_confirmed"] is False  # trams need 3 hits
    assert (by["all"]["pothole_hits"], by["all"]["pothole_passes"]) == (3, 5)


def test_sickness_is_duration_weighted_and_split_by_seat():
    # Observations finalized before sickness_s existed: weighted by their whole duration.
    rows = [_obs("a", "c1", "bus", 10, 1.0, aw=0.2, dur=1.0, seat="front"),
            _obs("b", "c1", "bus", 10, 1.0, aw=0.4, dur=3.0, seat="rear", posture="standing"),
            _obs("c", "c1", "bus", 10, 1.0, aw=9.0, dur=3.0, ok=False)]  # experimental: left out
    result = agg.compute(rows)
    bus = next(a for a in result.aggs if a["vehicle_type"] == "bus")
    expected = math.sqrt((0.2 ** 2 * 1 + 0.4 ** 2 * 3) / 4)
    assert bus["sickness_aw_rms"] == pytest.approx(expected)
    assert bus["msi_1h_pct"] == pytest.approx(expected * 60 / 3)
    assert bus["sickness_sessions"] == 2
    assert {(s["rater_seat"], s["rater_posture"]) for s in result.sickness} == {("front", "seated"), ("rear", "standing")}


def test_no_observations():
    result = agg.compute([])
    assert result.method == "none" and result.aggs == [] and result.n_sessions == 0


def test_eligibility_follows_the_exclusion_rules():
    assert agg.eligible(True, {"rigid": True, "handheld": False})
    assert not agg.eligible(True, {})  # rigid not stated: experimental, as on the dashboard
    assert not agg.eligible(False, {"rigid": True})
    assert not agg.eligible(True, {"rigid": False})
    assert not agg.eligible(True, {"handheld": True})


def test_hexagon_is_a_closed_ring_around_the_center():
    import h3

    cell = h3.latlng_to_cell(46.77, 23.62, agg.H3_RESOLUTION)
    point, polygon = agg._hexagon_wkt(cell)
    coords = polygon.removeprefix("POLYGON((").removesuffix("))").split(", ")
    assert coords[0] == coords[-1] and len(coords) == 7
    assert point.startswith("POINT(23.6") and " 46.7" in point
