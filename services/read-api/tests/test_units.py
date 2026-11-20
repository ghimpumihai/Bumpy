"""Pure helpers, no database needed."""

import datetime as dt
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from app.fmt import epoch_ms, iso  # noqa: E402
from app.queries import BadRequest, TrackPoint, enum_param, is_h3_cell, public_points  # noqa: E402

UTC = dt.timezone.utc


def test_iso_format_is_the_contract():
    t = dt.datetime(2026, 11, 21, 9, 12, 3, 512345, tzinfo=UTC)
    assert iso(t) == "2026-11-21T09:12:03.512Z"
    assert iso(t.astimezone(dt.timezone(dt.timedelta(hours=2)))) == "2026-11-21T09:12:03.512Z"
    assert iso(None) is None
    assert epoch_ms(t) == 1795252323512 and isinstance(epoch_ms(t), int)


def test_enum_param():
    assert enum_param(None, "x", ("a",)) is None and enum_param("", "x", ("a",)) is None
    assert enum_param("a", "x", ("a",)) == "a"
    try:
        enum_param("b", "x", ("a",))
        raise AssertionError("expected BadRequest")
    except BadRequest as e:
        assert "x must be one of a" in str(e)


def test_h3_cell():
    assert is_h3_cell("8a1fb46622dffff")
    assert not is_h3_cell("8a1fb46622dfff") and not is_h3_cell("7a1fb46622dffff")
    assert not is_h3_cell("8a1fb46622dfffz")


def _pts(distances):
    t0 = dt.datetime(2026, 1, 1, tzinfo=UTC)
    return [TrackPoint(0, 0, t0 + dt.timedelta(seconds=i), None, s) for i, s in enumerate(distances)]


def test_privacy_trim():
    pts = _pts([0, 100, 199, 200, 500, 800, 801, 1000])
    assert [p.s for p in public_points(pts, ended=False)] == [200, 500, 800, 801, 1000]
    assert [p.s for p in public_points(pts, ended=True)] == [200, 500, 800]
    assert public_points([], ended=True) == []
