"""The read API (plan §5, dashboard/API.md): GET-only JSON for the dashboard, as the `reader` role.

Run: uvicorn app.main:app --host 0.0.0.0 --port 8000

Telemetry: when APPLICATIONINSIGHTS_CONNECTION_STRING is set (Terraform does), requests, dependencies
and logs go to Application Insights through the Azure Monitor OpenTelemetry distro. Without it nothing
is configured, which is how tests and local runs work.
"""

from __future__ import annotations

import datetime as dt
import logging
import os
from contextlib import asynccontextmanager

import fastapi
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from psycopg import errors as pg_errors
from psycopg_pool import ConnectionPool, PoolTimeout
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from . import queries as q
from .db import make_pool

log = logging.getLogger("read-api")


class CatchErrors:
    """Turns an unhandled exception into the JSON 500 of API.md and logs it.

    Starlette sends `exception_handler(Exception)` responses from ServerErrorMiddleware, the outermost
    layer, i.e. outside CORSMiddleware: such a 500 has no Access-Control-Allow-Origin, so the browser
    reports a network error and the dashboard says "API unreachable". This middleware sits INSIDE
    CORSMiddleware, so the 500 it sends gets the CORS headers like every other response.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        started = False

        async def _send(message: Message) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            await self.app(scope, receive, _send)
        except Exception:
            log.exception("unhandled error on %s", scope.get("path"))
            if started:  # part of the response is already out; nothing valid can follow
                raise
            await JSONResponse({"error": "internal error"}, status_code=500)(scope, receive, send)


def configure_telemetry() -> bool:
    """Sends traces, logs and metrics to Application Insights if Terraform gave a connection string."""
    if not os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
        return False
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor

        configure_azure_monitor(logger_name="")  # reads the connection string from the environment
        # The Azure SDK logs every HTTP request at INFO, including the exporter's own uploads.
        logging.getLogger("azure").setLevel(logging.WARNING)
    except Exception:  # telemetry must never stop the API from serving
        log.exception("Application Insights telemetry could not be configured")
        return False
    return True


def create_app(pool: ConnectionPool | None = None) -> FastAPI:
    pool = pool or make_pool()
    stats_cache = q.TripStatsCache()  # per app, so per database

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        pool.open(wait=False)  # don't block start-up on the database; requests wait for a connection
        try:
            yield
        finally:
            pool.close()

    # fastapi.FastAPI looked up now, not at import: telemetry swaps in an instrumented class.
    app = fastapi.FastAPI(title="Road & Ride read API", docs_url=None, redoc_url=None, openapi_url=None,
                  lifespan=lifespan)

    # Added first, so it sits inside CORS (the last middleware added is the outermost).
    app.add_middleware(CatchErrors)
    origins = [o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "").split(",") if o.strip()]
    if origins:
        app.add_middleware(CORSMiddleware, allow_origins=origins, allow_methods=["GET"],
                           allow_headers=["*"], max_age=600)

    # --- errors: always {"error": "..."} (API.md) ----------------------------------------

    @app.exception_handler(q.NotFound)
    async def _not_found(_: Request, exc: q.NotFound):
        return JSONResponse({"error": str(exc)}, status_code=404)

    @app.exception_handler(q.BadRequest)
    async def _bad_request(_: Request, exc: q.BadRequest):
        return JSONResponse({"error": str(exc)}, status_code=400)

    @app.exception_handler(RequestValidationError)
    async def _invalid(_: Request, exc: RequestValidationError):
        return JSONResponse({"error": "invalid request parameters"}, status_code=400)

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException):
        message = f"no route for {request.url.path}" if exc.status_code == 404 else str(exc.detail)
        return JSONResponse({"error": message}, status_code=exc.status_code)

    @app.exception_handler(PoolTimeout)
    async def _busy(request: Request, exc: PoolTimeout):
        log.warning("no free database connection for %s", request.url.path)
        return JSONResponse({"error": "database busy, try again"}, status_code=503)

    @app.exception_handler(pg_errors.QueryCanceled)
    async def _slow(request: Request, exc: pg_errors.QueryCanceled):
        log.warning("statement timeout on %s: %s", request.url.path, exc)
        return JSONResponse({"error": "query took too long"}, status_code=503)

    # Last resort for errors outside CatchErrors (in the CORS middleware itself): still JSON.
    @app.exception_handler(Exception)
    async def _crash(request: Request, exc: Exception):
        log.exception("unhandled error on %s", request.url.path)
        return JSONResponse({"error": "internal error"}, status_code=500)

    # --- routes --------------------------------------------------------------------------
    # Plain `def` endpoints run in FastAPI's thread pool, so blocking psycopg calls are fine.

    @app.get("/api/overview")
    def overview():
        with pool.connection() as conn:
            return q.overview(conn)

    @app.get("/api/sessions")
    def sessions(source: str | None = None, vehicle: str | None = None):
        source = q.enum_param(source, "source", q.SOURCES)
        vehicle = q.enum_param(vehicle, "vehicle", q.VEHICLE_TYPES)
        with pool.connection() as conn:
            return q.session_list(conn, source, vehicle, stats_cache)

    @app.get("/api/sessions/{session_id}")
    def session(session_id: str):
        with pool.connection() as conn:
            return q.session_detail(conn, session_id, stats_cache)

    @app.get("/api/sessions/{session_id}/series")
    def series(session_id: str):
        with pool.connection() as conn:
            return q.session_series(conn, session_id)

    @app.get("/api/sessions/{session_id}/track")
    def track(session_id: str):
        with pool.connection() as conn:
            return q.session_track(conn, session_id)

    @app.get("/api/sessions/{session_id}/events")
    def session_events(session_id: str):
        with pool.connection() as conn:
            return q.session_events(conn, session_id)

    @app.get("/api/sessions/{session_id}/labels")
    def labels(session_id: str):
        with pool.connection() as conn:
            return q.session_labels(conn, session_id)

    @app.get("/api/segments")
    def segments(vehicle: str | None = None):
        vehicle = q.enum_param(vehicle, "vehicle", q.VEHICLE_FILTERS)
        with pool.connection() as conn:
            return q.segments(conn, vehicle)

    @app.get("/api/segments/{h3}")
    def segment(h3: str):
        if not q.is_h3_cell(h3):
            raise q.BadRequest(f"{h3} is not an H3 cell")
        with pool.connection() as conn:
            return q.segment_detail(conn, h3)

    @app.get("/api/events")
    def events(vehicle: str | None = None, type: str | None = None):  # noqa: A002 - API.md name
        vehicle = q.enum_param(vehicle, "vehicle", q.VEHICLE_FILTERS)
        etype = q.enum_param(type, "type", q.EVENT_TYPES)
        with pool.connection() as conn:
            return q.all_events(conn, vehicle, etype)

    @app.get("/api/live")
    def live():
        with pool.connection() as conn:
            return q.live(conn, dt.datetime.now(dt.timezone.utc))

    @app.get("/api/quality")
    def quality():
        with pool.connection() as conn:
            return q.quality_list(conn, stats_cache)

    return app


# Console logging first: basicConfig does nothing once telemetry has added its handler to the root logger.
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
configure_telemetry()  # before create_app, so FastAPI is instrumented
app = create_app()  # the pool connects when the app starts, not at import
