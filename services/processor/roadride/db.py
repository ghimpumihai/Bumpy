"""PostgreSQL connections.

Connection settings come from the standard libpq variables (PGHOST, PGDATABASE, PGUSER, PGPORT,
PGSSLMODE), set by Terraform on Azure. There, AZURE_CLIENT_ID names the service's managed identity and
the password is a Microsoft Entra token for it (plan §5 "Database logins"); a token is only needed to
open a connection. Locally and in CI, PGPASSWORD (from your environment or the POSTGRES_PASSWORD repo
secret) is used as is.
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
    if os.environ.get("AZURE_CLIENT_ID") and not os.environ.get("PGPASSWORD"):
        kwargs["password"] = _entra_token()
    if dbname:
        kwargs["dbname"] = dbname
    return psycopg.connect(**kwargs)
