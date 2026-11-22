# Read API

The dashboard's only backend (plan §5, contract in [`dashboard/API.md`](../../dashboard/API.md)). FastAPI on port 8000, logged in to PostgreSQL as the read-only `reader` role. It runs as a Container App with public HTTPS ingress, and browsers may only call it from the dashboard's own origin (`CORS_ALLOWED_ORIGINS`, set by Terraform).

## What each route returns today

| Route | Data |
|---|---|
| `/api/live` | Devices heard from in the last 60 s (`live_state`), with the last 2 minutes of track, `roughnessNow` and `msdvSoFar`. A device is listed from its first position, including for up to 60 s after its trip ends (D40). |
| `/api/sessions`, `/api/sessions/{id}`, `/api/quality` | Built from `sessions`, `track_points`, `events` and `ingest_batches`. Missing context gets the defaults the dashboard expects. Fills in distance (whole track length; `sessions.distance_m` once finalized), `msdv`/`msdvZ`/`msdvY`/`msiPct` (combined = √(z² + y²), D49), public event counts, GPS accuracy, per-stream quality, `validFraction`/`invalidSeconds`/`processedAt` from the finalize job, and late and duplicate batch counts. |
| `/api/sessions/{id}/track` | 1 Hz track, whole (no start/end trim, D40); fixes less accurate than 50 m are left out. |
| `/api/sessions/{id}/series` | The 5 Hz chart series from the signal processing. |
| `/api/sessions/{id}/events` | Detected events that have a position. |
| `/api/sessions/{id}/labels` | The trip's labels, without the `sickness` ratings older app builds still send (D47). |
| `/api/events` | Events of **aggregated** (finalized) trips only, that have a position. |
| `/api/overview` | Session counts, distance of aggregated trips, segment, confirmed-pothole and speed-bump counts and the latest aggregation fit (`aggregation_fit`). |
| `/api/segments`, `/api/segments/{h3}` | `segments` + `segment_agg` (+ `segment_sickness`, `segment_observations`) from the aggregate job. Every pass is served, including ones flagged `in_privacy_zone` before D40. `/api/segments/{h3}` answers 404 for a cell that isn't in `segments` (no pass of an aggregated trip) and 400 for anything that isn't an H3 cell; `byVehicle` lists only the map filters (`all`, `car`, `bus`, `tram`). |
| `/api/heat` | One `MultiLineString` per aggregated trip (`include_in_agg`) from its accurate `track_points`, cut where the GPS went quiet for over 10 s or jumped over ~200 m, simplified in PostGIS to within ~2 m (`ST_Simplify`); lines shorter than ~4 m are dropped. |

Query parameters: `/api/sessions?source=&vehicle=`, `/api/segments?vehicle=` and `/api/events?vehicle=&type=` (all optional).

Errors are always `{"error": "..."}`, with the CORS headers like any other answer (a 500 without them looks like a network error to the browser): 404 for an unknown session, segment or route, 400 for a bad query parameter (same allowed values as the mock), 503 when no database connection is free in time, a statement hits its timeout or the database connection fails, 500 for anything else (logged with its stack trace). Times are `2026-11-21T09:12:03.512Z`; epoch milliseconds are integers.

`quality.streams` is the finalize job's (from the whole trip, `sessions.quality`) once a trip is finalized, under the dashboard's stream names (`deviceMotion` → `device_motion`). Before that it comes from the live batches (`ingest_batches.sample_counts`): rows, rate over the trip, and the longest pause between two batches carrying the stream. Gaps inside a batch aren't visible to the live path, `mag_raw` and `device` aren't counted by the processor, and an uploaded trip has `{}` until it is finalized.

`detection` comes from the finalize job (`sessions.quality.detection`, scored against the manual taps) and is `null` until a trip is finalized. Speed bumps come from the processor; rail joints are a tram trip's potholes, relabelled by the finalize job (D42).

## No privacy trim (D40)

Positions are served whole: no start or end zone is hidden, on any route. The only filter is accuracy: fixes without an accuracy or worse than 50 m (`MAX_HACC_M` in `app/queries.py`) are never returned. Anyone with the dashboard link can see where trips start and end.

## Performance

No route runs a query per trip. `/api/live` reads only the last 2 minutes of each live track. Track length (until a trip is finalized and has `sessions.distance_m`), GPS accuracy, live stream quality and the heat map lines read a whole trip, so they are cached per trip until its `sessions.updated_at` or `status` changes (the processor bumps `updated_at` with every batch and session message; a job that rewrites a trip's track or batches must do the same). On a cold cache they are computed 25 trips per statement (`STATS_CHUNK`), each chunk cached as soon as it is done, so no statement grows with the number of trips and a timeout part-way loses nothing. The heat lines are built as GeoJSON text in PostGIS, so fixes never become Python objects.

`people.raterPosture` (and the posture in `sicknessBySeat`) is `seated` unless the stored value is one of the app's `seated` / `standing`.

| Env var | Default | |
|---|---|---|
| `READ_API_POOL_MAX_SIZE` | 5 | database connections per replica |
| `READ_API_POOL_TIMEOUT_S` | 10 | wait for a free connection, then 503 |
| `READ_API_STATEMENT_TIMEOUT_MS` | 10000 | the server cancels a slower statement (503) |

## Telemetry

When `APPLICATIONINSIGHTS_CONNECTION_STRING` is set (Terraform sets it), `configure_azure_monitor()` sends requests, logs and exceptions to Application Insights (`azure-monitor-opentelemetry`). Without it, nothing is configured.

## Database login

On Azure, `PGUSER=reader` and each new connection gets a fresh Microsoft Entra token for the identity in `AZURE_CLIENT_ID`. The pool passes the token per connection (`app/db.py`), so it keeps working after the first token expires. Locally and in CI, `PGPASSWORD` is used.

## Tests

`tests/test_api.py` writes data through the stream processor's own `Store`, reads it back through the API against a real PostGIS, and checks every response's keys against the dashboard's TypeScript types. CI runs it (`.github/workflows/read-api-ci.yml`); locally it needs the docker-compose database:

```powershell
$env:PGHOST='localhost'; $env:PGPORT='5433'; $env:PGUSER='postgres'; $env:PGPASSWORD=$env:POSTGRES_PASSWORD
```
```powershell
cd services/read-api; python -m pytest -q -rs tests
```

## Deploy

`deploy-services.yml` builds this image alongside the processor on every merge to `main` that touches `services/read-api/`, `services/processor/` or `db/`, updates the Container App (switching its ingress to port 8000 on a fresh stack), waits until `GET /api/overview` answers 200, then requires 200 from `/api/overview`, `/api/sessions`, `/api/quality`, `/api/live`, `/api/heat` and `/api/segments?vehicle=all` (which proves the Entra login and the `reader` grants work). Then run **deploy-dashboard** from the Actions tab: it points the dashboard's `config.json` at this API and uploads the site.
