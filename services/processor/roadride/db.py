"""PostgreSQL connections.

Connection settings come from the standard libpq variables (PGHOST, PGDATABASE, PGUSER, PGPORT,
PGSSLMODE), set by Terraform on Azure and by docker-compose locally. With PGPASSWORD set (local
PostGIS) it is used as is; otherwise the password is a Microsoft Entra token for the managed identity
in AZURE_CLIENT_ID (plan §5 "Database logins"). A token is only needed to open a connection.
"""

from __future__ import annotations

import os

import psycopg

ENTRA_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"

_credential = None


def _entra_token() -> str:
    global _credential
    if _credential is None:
        from azure.identity import DefaultAzureCredential  # only needed on Azure

        _credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    return _credential.get_token(ENTRA_SCOPE).token


def connect(*, autocommit: bool = False, dbname: str | None = None,
            application_name: str = "roadride") -> psycopg.Connection:
    kwargs: dict = {"autocommit": autocommit, "application_name": application_name}
    if not os.environ.get("PGPASSWORD"):
        kwargs["password"] = _entra_token()
    if dbname:
        kwargs["dbname"] = dbname
    return psycopg.connect(**kwargs)
