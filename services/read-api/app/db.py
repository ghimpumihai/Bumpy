"""Read-only database access for the read API.

Connection settings come from the libpq variables set by Terraform (PGHOST, PGDATABASE, PGUSER=reader,
PGSSLMODE). On Azure (AZURE_CLIENT_ID set) the password is a Microsoft Entra token. Tokens expire after
about an hour, so the token is fetched for EVERY new connection (TokenConnection.connect), never once
for the pool. Locally and in CI, PGPASSWORD is used instead.
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


def make_pool(dbname: str | None = None) -> ConnectionPool:
    kwargs: dict = {"autocommit": True, "application_name": "roadride-read-api"}
    if dbname:
        kwargs["dbname"] = dbname
    return ConnectionPool(
        conninfo="",
        connection_class=TokenConnection,
        kwargs=kwargs,
        min_size=1,
        max_size=5,
        max_lifetime=50 * 60,  # recycle before tokens would matter for anything but opening
        check=ConnectionPool.check_connection,  # drop connections the server closed
        open=False,
        name="read-api",
    )
