"""Seeds a PostGIS database for the dashboard's real-API end-to-end tests (e2e/real-api.spec.ts).

Data goes in through the stream processor's own write path (roadride.store.Store, the code that runs on
Azure), starting from the batch the iPhone app's real encoder produced
(src/mobile-ios/tools/fixtures/ingest_batch_v1.json.gz), so the read API answers exactly as in production.

Three trips, one per state the dashboard must handle:
- LIVE: recording now, so it shows on the live view;
- ENDED: Stop received and every batch in, so it is being processed;
- NO_CONTEXT: batches only, session.json never arrived (unknown context).

Usage (libpq variables select the database): python3 dashboard/e2e/real-api/seed.py
Every run starts from empty tables (re-sent batches would be dropped as duplicates and the live trip would
look old), so the database name must contain "e2e": the script refuses to touch any other database.
"""

from __future__ import annotations

import copy
import datetime as dt
import gzip
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "services" / "processor"))

import psycopg  # noqa: E402

from roadride.live import parse_batch, parse_session  # noqa: E402
from roadride.migrate import apply_migrations  # noqa: E402
from roadride.store import Store  # noqa: E402

FIXTURE = ROOT / "src" / "mobile-ios" / "tools" / "fixtures" / "ingest_batch_v1.json.gz"
MIGRATIONS = ROOT / "db" / "migrations"
UTC = dt.timezone.utc

LIVE = "e2e00000-0000-4000-8000-00000000live"
ENDED = "e2e00000-0000-4000-8000-0000000ended"
NO_CONTEXT = "e2e00000-0000-4000-8000-00000context"
BATCH_S = 2
# 20 m per batch eastwards (≈ 36 km/h): 40 batches = 800 m.
STEP_DEG_LON = 20 / 75_000  # ~75 km per degree of longitude at 47.6° N
START = (47.60, 8.50)


def iso(t: dt.datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def batch(template: dict, session_id: str, device_id: str, seq: int, start: dt.datetime, origin_lon: float) -> dict:
    b = copy.deepcopy(template)
    t0 = start + dt.timedelta(seconds=BATCH_S * seq)
    t0_ms = int(t0.timestamp() * 1000)
    b.update(sessionId=session_id, deviceId=device_id, batchSeq=seq, t0UtcMs=t0_ms, t0Utc=iso(t0),
             t0Up=5000.0 + BATCH_S * seq, labels=[])
    b["location"] = [dict(b["location"][0], tUtcMs=t0_ms + 500, lat=START[0],
                          lon=origin_lon + seq * STEP_DEG_LON, speed=10.0, hAcc=5.0)]
    return b


def meta(session_id: str, device_id: str, started: dt.datetime, *, ended: dt.datetime | None = None,
         batch_count: int | None = None) -> dict:
    m = {
        "sessionId": session_id, "deviceId": device_id, "startedAtUtc": iso(started), "startUptimeSec": 10.0,
        "endedAtUtc": iso(ended) if ended else None, "recovered": False, "syntheticSensors": False,
        "audioEnabled": False,
        "vehicle": {"type": "bus", "makeModel": "Solaris Urbino 12", "line": "24", "notes": ""},
        "mount": {"location": "dashboard holder", "phoneOrientation": "flat", "rigid": True, "handheld": False},
        "people": {"operatorSeat": "front", "raterSeat": "rear left", "raterPosture": "seated", "passengerCount": 2},
    }
    if batch_count is not None:
        m["batchCount"] = batch_count
    return m


def main() -> None:
    template = json.loads(gzip.decompress(FIXTURE.read_bytes()))
    now = dt.datetime.now(UTC)
    n = 40
    with psycopg.connect(autocommit=True) as conn:
        dbname = conn.info.dbname
        if "e2e" not in dbname:
            sys.exit(f"refusing to reset database {dbname!r}: use a dedicated database whose name contains 'e2e'")
        apply_migrations(conn, MIGRATIONS)
        tables = [r[0] for r in conn.execute(
            "SELECT format('%I', tablename) FROM pg_tables WHERE schemaname = 'public' "
            "AND tablename NOT IN ('schema_migrations', 'spatial_ref_sys')").fetchall()]
        if tables:
            conn.execute(f"TRUNCATE {', '.join(tables)} RESTART IDENTITY CASCADE")
    with psycopg.connect() as conn:
        store = Store(conn)
        with conn.transaction():
            # Recording now: the newest batch is from a moment ago and just arrived.
            live_start = now - dt.timedelta(seconds=BATCH_S * n)
            store.apply_session(parse_session(meta(LIVE, "E2E-PHONE-LIVE", live_start)))
            for seq in range(n):
                store.apply_batch(parse_batch(batch(template, LIVE, "E2E-PHONE-LIVE", seq, live_start, START[1])), now)

            # Ended an hour ago: Start, every batch, then Stop with the exact batch count.
            ended_start = now - dt.timedelta(hours=1, seconds=BATCH_S * n)
            ended_end = ended_start + dt.timedelta(seconds=BATCH_S * n)
            store.apply_session(parse_session(meta(ENDED, "E2E-PHONE-ENDED", ended_start)))
            for seq in range(n):
                store.apply_batch(parse_batch(batch(template, ENDED, "E2E-PHONE-ENDED", seq, ended_start, START[1] + 0.05)),
                                  ended_start + dt.timedelta(seconds=BATCH_S * seq + 1))
            store.apply_session(parse_session(meta(ENDED, "E2E-PHONE-ENDED", ended_start, ended=ended_end, batch_count=n)))

            # session.json never arrived: the read API fills the context with empty defaults.
            nc_start = now - dt.timedelta(hours=3)
            for seq in range(n):
                store.apply_batch(parse_batch(batch(template, NO_CONTEXT, "E2E-PHONE-NOCTX", seq, nc_start, START[1] + 0.1)),
                                  nc_start + dt.timedelta(seconds=BATCH_S * seq + 1))
    print(f"seeded {LIVE}, {ENDED}, {NO_CONTEXT}")


if __name__ == "__main__":
    main()
