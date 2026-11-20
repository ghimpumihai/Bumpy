"""The migrate job (plan §5 "Migrations run once, in their own job").

1. Applies db/migrations/*.sql in name order, each in its own transaction, recording them in
   schema_migrations. An advisory lock makes concurrent runs wait instead of racing.
2. On Azure (WRITER_OBJECT_ID / READER_OBJECT_ID set): creates the Entra roles `writer` and
   `reader` for the services' managed identities and grants their rights. Locally both are skipped
   and everything runs as the PostGIS superuser.

Runs as the Entra admin `migrator`, so the tables it creates are owned by migrator.
"""

from __future__ import annotations

import logging
import os
import pathlib

from psycopg import Connection, sql

from .db import connect

log = logging.getLogger(__name__)

LOCK_ID = 7_202_611_21  # any constant; shared by every migrate run

ROLES = {"writer": "WRITER_OBJECT_ID", "reader": "READER_OBJECT_ID"}

GRANTS = [
    "GRANT USAGE ON SCHEMA public TO writer, reader",
    "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO writer",
    "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO writer",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO reader",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO writer",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO writer",
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO reader",
]


def default_migrations_dir() -> pathlib.Path:
    env = os.environ.get("MIGRATIONS_DIR")
    if env:
        return pathlib.Path(env)
    return pathlib.Path(__file__).resolve().parents[3] / "db" / "migrations"


def apply_migrations(conn: Connection, migrations_dir: pathlib.Path) -> list[str]:
    """Returns the versions applied in this run. `conn` must be in autocommit mode."""
    files = sorted(migrations_dir.glob("*.sql"))
    if not files:
        raise FileNotFoundError(f"no migrations in {migrations_dir}")
    conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_ID,))
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations ("
                     "version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())")
        done = {r[0] for r in conn.execute("SELECT version FROM schema_migrations").fetchall()}
        applied = []
        for f in files:
            if f.stem in done:
                continue
            log.info("applying %s", f.name)
            with conn.transaction():
                conn.execute(f.read_text(encoding="utf-8"))
                conn.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (f.stem,))
            applied.append(f.stem)
        return applied
    finally:
        conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_ID,))


def ensure_entra_roles(admin_db_conn: Connection, object_ids: dict[str, str]) -> None:
    """Creates missing Entra roles. Roles are server-wide; pgaadauth lives in the `postgres` database."""
    for role, oid in object_ids.items():
        exists = admin_db_conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone()
        if exists:
            continue
        log.info("creating Entra role %s", role)
        # The server matches tokens to roles by object ID, not by name (plan §5).
        admin_db_conn.execute(
            "SELECT * FROM pgaadauth_create_principal_with_oid(%s, %s, 'service', false, false)",
            (role, oid),
        )


def grant_rights(conn: Connection) -> None:
    for stmt in GRANTS:
        conn.execute(sql.SQL(stmt))


def run() -> None:
    migrations_dir = default_migrations_dir()
    with connect(autocommit=True, application_name="roadride-migrate") as conn:
        applied = apply_migrations(conn, migrations_dir)
        log.info("migrations applied: %s", ", ".join(applied) or "none (up to date)")

        object_ids = {role: os.environ[var] for role, var in ROLES.items() if os.environ.get(var)}
        if len(object_ids) == len(ROLES):
            with connect(autocommit=True, dbname="postgres", application_name="roadride-migrate") as admin:
                ensure_entra_roles(admin, object_ids)
            grant_rights(conn)
            log.info("roles writer and reader are up to date")
        else:
            log.info("WRITER_OBJECT_ID / READER_OBJECT_ID not set: skipping Entra roles (local run)")
