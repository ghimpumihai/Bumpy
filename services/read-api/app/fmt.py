"""One way to write times, used everywhere: `2026-11-21T09:12:03.512Z` (dashboard/API.md)."""

from __future__ import annotations

import datetime as dt

UTC = dt.timezone.utc


def iso(value: dt.datetime | None) -> str | None:
    if value is None:
        return None
    value = value.astimezone(UTC)
    return value.strftime("%Y-%m-%dT%H:%M:%S.") + f"{value.microsecond // 1000:03d}Z"


def epoch_ms(value: dt.datetime) -> int:
    return int(round(value.timestamp() * 1000))


def rnd(value: float | None, digits: int = 6) -> float | None:
    return None if value is None else round(float(value), digits)
