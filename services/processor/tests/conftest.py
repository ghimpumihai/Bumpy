import copy
import gzip
import json
import os
import pathlib
import sys
import uuid

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FIXTURE = ROOT / "src" / "mobile-ios" / "tools" / "fixtures" / "ingest_batch_v1.json.gz"
MIGRATIONS = ROOT / "db" / "migrations"


@pytest.fixture(scope="session")
def _fixture_batch():
    return json.loads(gzip.decompress(FIXTURE.read_bytes()))


@pytest.fixture
def batch(_fixture_batch):
    return copy.deepcopy(_fixture_batch)


@pytest.fixture
def session_meta(batch):
    return {
        "sessionId": batch["sessionId"],
        "deviceId": batch["deviceId"],
        "startedAtUtc": "2025-11-21T09:15:30.000Z",
        "startUptimeSec": 98.0,
        "endedAtUtc": None,
        "recovered": False,
        "syntheticSensors": False,
        "audioEnabled": False,
        "vehicle": {"type": "bus", "makeModel": "Solaris Urbino 12", "line": "24", "notes": ""},
        "mount": {"location": "dash", "phoneOrientation": "flat", "rigid": True, "handheld": False},
        "people": {"operatorSeat": "front", "raterSeat": "rear left", "raterPosture": "seated",
                   "passengerCount": 2},
        "conditions": {"weather": "dry", "notes": ""},
    }


# --- Integration tests: a real PostGIS (CI service container or docker-compose) ------------

def _have_db() -> bool:
    if not os.environ.get("PGHOST"):
        return False
    try:
        import psycopg  # noqa: F401
    except ImportError:
        return False
    return True


requires_db = pytest.mark.skipif(not _have_db(), reason="needs PGHOST (local PostGIS) and psycopg")


@pytest.fixture
def db():
    """A fresh, migrated database per test; dropped afterwards."""
    import psycopg

    from roadride.migrate import apply_migrations

    name = f"rr_test_{uuid.uuid4().hex[:10]}"
    with psycopg.connect(dbname="postgres", autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    try:
        with psycopg.connect(dbname=name, autocommit=True) as conn:
            apply_migrations(conn, MIGRATIONS)
        conn = psycopg.connect(dbname=name)
        yield conn
        conn.close()
    finally:
        with psycopg.connect(dbname="postgres", autocommit=True) as admin:
            admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
