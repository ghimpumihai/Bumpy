"""Tests run the real write path: data is seeded through the stream processor's Store (the same code
that runs on Azure), then read back through the API against a real PostGIS."""

import copy
import datetime as dt
import gzip
import json
import os
import pathlib
import sys
import uuid

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "services" / "read-api"))
sys.path.insert(0, str(ROOT / "services" / "processor"))

FIXTURE = ROOT / "src" / "mobile-ios" / "tools" / "fixtures" / "ingest_batch_v1.json.gz"
MIGRATIONS = ROOT / "db" / "migrations"

UTC = dt.timezone.utc


def _have_db() -> bool:
    if not os.environ.get("PGHOST") or not os.environ.get("PGPASSWORD"):
        return False
    try:
        import fastapi  # noqa: F401
        import psycopg  # noqa: F401
    except ImportError:
        return False
    return True


requires_db = pytest.mark.skipif(not _have_db(), reason="needs PGHOST/PGPASSWORD, psycopg and fastapi")


@pytest.fixture(scope="session")
def fixture_batch():
    return json.loads(gzip.decompress(FIXTURE.read_bytes()))


@pytest.fixture
def dbname():
    import psycopg

    from roadride.migrate import apply_migrations

    name = f"rr_api_{uuid.uuid4().hex[:10]}"
    with psycopg.connect(dbname="postgres", autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    try:
        with psycopg.connect(dbname=name, autocommit=True) as conn:
            apply_migrations(conn, MIGRATIONS)
        yield name
    finally:
        with psycopg.connect(dbname="postgres", autocommit=True) as admin:
            admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


@pytest.fixture
def seed(dbname, fixture_batch):
    """seed(batches=..., meta=...) writes through the processor's Store."""
    import psycopg

    from roadride.live import parse_batch, parse_session
    from roadride.store import Store

    def _seed(batches=(), meta=(), received_at=None):
        with psycopg.connect(dbname=dbname) as conn:
            store = Store(conn)
            with conn.transaction():
                for m in meta:
                    store.apply_session(parse_session(m))
                for b in batches:
                    store.apply_batch(parse_batch(b), received_at or dt.datetime.now(UTC))
    return _seed


@pytest.fixture
def client(dbname):
    from fastapi.testclient import TestClient

    from app.db import make_pool
    from app.main import create_app

    with TestClient(create_app(make_pool(dbname))) as c:
        yield c


def make_batch(template: dict, session_id: str, seq: int, start: dt.datetime, lat: float, lon: float,
               *, device_id: str = "PHONE-1", labels=()) -> dict:
    """One batch with a single GPS fix, `seq` × 2 s after `start`."""
    b = copy.deepcopy(template)
    t0 = start + dt.timedelta(seconds=2 * seq)
    t0_ms = int(t0.timestamp() * 1000)
    b.update(sessionId=session_id, deviceId=device_id, batchSeq=seq, t0UtcMs=t0_ms,
             t0Up=5000.0 + 2 * seq,  # phone uptime advances with the batches
             t0Utc=t0.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t0.microsecond // 1000:03d}Z",
             labels=list(labels))
    b["location"] = [dict(b["location"][0], tUtcMs=t0_ms + 500, lat=lat, lon=lon, speed=10.0)]
    return b


def session_meta(session_id: str, *, device_id: str = "PHONE-1", vehicle: str = "bus", **extra) -> dict:
    m = {
        "sessionId": session_id, "deviceId": device_id, "startedAtUtc": "2026-11-21T09:00:00.000Z",
        "startUptimeSec": 10.0, "endedAtUtc": None, "recovered": False, "syntheticSensors": False,
        "audioEnabled": False,
        "vehicle": {"type": vehicle, "makeModel": "Solaris Urbino 12", "line": "24", "notes": ""},
        "mount": {"location": "dash", "phoneOrientation": "flat", "rigid": True, "handheld": False},
        "people": {"operatorSeat": "front", "raterSeat": "rear left", "raterPosture": "seated",
                   "passengerCount": 2},
    }
    m.update(extra)
    return m
