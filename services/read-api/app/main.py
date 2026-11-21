"""The read API (plan §5, dashboard/API.md): GET-only JSON for the dashboard, as the `reader` role.

Run: uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import datetime as dt
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from psycopg_pool import ConnectionPool
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import queries as q
from .db import make_pool

log = logging.getLogger("read-api")


def create_app(pool: ConnectionPool | None = None) -> FastAPI:
    pool = pool or make_pool()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        pool.open(wait=False)  # don't block start-up on the database; requests wait for a connection
        try:
            yield
        finally:
            pool.close()

    app = FastAPI(title="Road & Ride read API", docs_url=None, redoc_url=None, openapi_url=None,
                  lifespan=lifespan)

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
            return q.session_list(conn, source, vehicle)

    @app.get("/api/sessions/{session_id}")
    def session(session_id: str):
        with pool.connection() as conn:
            return q.session_detail(conn, session_id)

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
        q.enum_param(vehicle, "vehicle", q.VEHICLE_FILTERS)
        return q.empty_feature_collection()

    @app.get("/api/segments/{h3}")
    def segment(h3: str):
        return q.segment_detail(h3)

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
            return q.quality_list(conn)

    return app


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
app = create_app()  # the pool connects when the app starts, not at import
