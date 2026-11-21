"""One way to write times, used everywhere: `2026-11-21T09:12:03.512Z` (dashboard/API.md)."""

from __future__ import annotations

import datetime as dt

UTC = dt.timezone.utc


def iso(value: dt.datetime | None) -> str | None:
    if value is None:
        return None
    value = value.astimezone(UTC)
    return value.strftime("%Y-%m-%dT%H:%M:%S.") + f"{value.microsecond // 1000:03d}Z"


_EPOCH = dt.datetime(1970, 1, 1, tzinfo=UTC)


def epoch_ms(value: dt.datetime) -> int:
    # Truncated like iso(), in exact integer arithmetic, so an event's id/series ms and its tUtc agree.
    return (value.astimezone(UTC) - _EPOCH) // dt.timedelta(milliseconds=1)


def rnd(value: float | None, digits: int = 6) -> float | None:
    return None if value is None else round(float(value), digits)
