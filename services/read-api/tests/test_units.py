"""Pure helpers, no database needed."""

import datetime as dt
import sys
import pathlib

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from app.fmt import epoch_ms, iso  # noqa: E402
from app import queries  # noqa: E402
from app.queries import BadRequest, TripStatsCache, enum_param, is_h3_cell  # noqa: E402

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


def test_cold_cache_is_filled_chunk_by_chunk(monkeypatch):
    """A statement per STATS_CHUNK trips, each cached when done: a failure part-way (statement timeout)
    keeps what was computed, so the next request only does the rest."""
    monkeypatch.setattr(queries, "STATS_CHUNK", 2)
    rows = [{"session_id": f"s{i}", "version_at": 1, "status": "complete"} for i in range(5)]
    calls = []

    def compute(ids):
        calls.append(ids)
        if ids == ["s2", "s3"] and len(calls) == 2:
            raise TimeoutError
        return {sid: sid.upper() for sid in ids}

    cache = TripStatsCache()
    with pytest.raises(TimeoutError):
        cache.get_many("track", rows, compute)
    assert cache.get_many("track", rows, compute) == {f"s{i}": f"S{i}" for i in range(5)}
    assert calls == [["s0", "s1"], ["s2", "s3"], ["s2", "s3"], ["s4"]]
    assert cache.get_many("track", rows, compute) and len(calls) == 4  # all cached now

    rows[4] = {**rows[4], "version_at": 2}  # a trip that changed is the only one recomputed
    cache.get_many("track", rows, compute)
    assert calls[4:] == [["s4"]]



def test_telemetry_off_without_connection_string(monkeypatch):
    pytest.importorskip("fastapi")
    pytest.importorskip("psycopg")
    from app.main import configure_telemetry

    monkeypatch.delenv("APPLICATIONINSIGHTS_CONNECTION_STRING", raising=False)
    assert configure_telemetry() is False


def test_epoch_ms_and_iso_name_the_same_millisecond():
    """iso() truncates to the ms; epoch_ms rounded, so an event's id/series ms and its tUtc could
    differ by 1 ms."""
    t = dt.datetime(2026, 11, 21, 9, 12, 3, 512999, tzinfo=UTC)
    assert iso(t) == "2026-11-21T09:12:03.512Z" and epoch_ms(t) == 1795252323512
    ms = epoch_ms(t)
    assert dt.datetime.fromtimestamp(ms / 1000, UTC).strftime("%S.%f")[:6] == iso(t)[17:23]
