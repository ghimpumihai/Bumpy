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


# SQLSTATEs that mean the server ended the session: admin_shutdown, crash_shutdown, cannot_connect_now.
_SERVER_GONE = {"57P01", "57P02", "57P03"}


def is_connection_loss(exc: BaseException, conn: psycopg.Connection | None) -> bool:
    """True when `exc` means the connection is gone, so the work should be retried on a new one.

    psycopg raises OperationalError for much more than lost connections (index row too large, disk
    full, out of memory, statement or lock timeouts, ...). Those come back the same way on every
    retry, so they must not be treated as "reconnect and try again" or the event would block its
    partition forever.
    """
    if conn is not None and (conn.broken or conn.closed):
        return True
    if not isinstance(exc, psycopg.Error):
        return False
    sqlstate = exc.sqlstate
    if sqlstate is None:
        # Raised by the client itself: only connection trouble surfaces as OperationalError there.
        return isinstance(exc, psycopg.OperationalError)
    return sqlstate.startswith("08") or sqlstate in _SERVER_GONE


def is_retryable_conflict(exc: BaseException) -> bool:
    """Deadlock or serialization failure (SQLSTATE class 40): the same statements usually succeed
    when run again."""
    sqlstate = exc.sqlstate if isinstance(exc, psycopg.Error) else None
    return bool(sqlstate) and sqlstate.startswith("40")  # psycopg doesn't subclass these by class
