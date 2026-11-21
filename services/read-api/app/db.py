"""Read-only database access for the read API.

Connection settings come from the libpq variables set by Terraform (PGHOST, PGDATABASE, PGUSER=reader,
PGSSLMODE). On Azure (AZURE_CLIENT_ID set) the password is a Microsoft Entra token. Tokens expire after
about an hour, so the token is fetched for EVERY new connection (TokenConnection.connect), never once
for the pool. Locally and in CI, PGPASSWORD is used instead.

Sizing (env, all optional): READ_API_POOL_MAX_SIZE (default 5 connections), READ_API_POOL_TIMEOUT_S
(default 10 s to wait for a free connection, then 503), READ_API_STATEMENT_TIMEOUT_MS (default 10000:
the server cancels a slower statement, so one bad query can't hold a connection for long).
"""

from __future__ import annotations

import os

import psycopg
from psycopg_pool import ConnectionPool

ENTRA_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"

_credential = None


def _entra_token() -> str:
    global _credential
    if _credential is None:
        from azure.identity import DefaultAzureCredential

        _credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    return _credential.get_token(ENTRA_SCOPE).token


class TokenConnection(psycopg.Connection):
    @classmethod
    def connect(cls, conninfo: str = "", **kwargs):  # type: ignore[override]
        if os.environ.get("AZURE_CLIENT_ID") and not os.environ.get("PGPASSWORD"):
            kwargs["password"] = _entra_token()
        return super().connect(conninfo, **kwargs)


def _env_number(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    value = float(raw)
    if value <= 0:
        raise ValueError(f"{name} must be positive, got {raw!r}")
    return value


def make_pool(dbname: str | None = None) -> ConnectionPool:
    statement_timeout_ms = int(_env_number("READ_API_STATEMENT_TIMEOUT_MS", 10_000))
    kwargs: dict = {"autocommit": True, "application_name": "roadride-read-api",
                    # Sent in the startup packet: applies to every statement on the connection. PostGIS's
                    # cost estimates trip the JIT threshold, and compiling took longer (~0.7 s) than running
                    # these sub-second queries.
                    "options": f"-c statement_timeout={statement_timeout_ms} -c jit=off"}
    if dbname:
        kwargs["dbname"] = dbname
    return ConnectionPool(
        conninfo="",
        connection_class=TokenConnection,
        kwargs=kwargs,
        min_size=1,
        max_size=int(_env_number("READ_API_POOL_MAX_SIZE", 5)),
        timeout=_env_number("READ_API_POOL_TIMEOUT_S", 10.0),
        max_lifetime=50 * 60,  # recycle before tokens would matter for anything but opening
        check=ConnectionPool.check_connection,  # drop connections the server closed
        open=False,
        name="read-api",
    )
