# Read API

The dashboard's only backend (plan §5, contract in [`dashboard/API.md`](../../dashboard/API.md)). FastAPI on port 8000, logged in to PostgreSQL as the read-only `reader` role. It runs as a Container App with public HTTPS ingress, and browsers may only call it from the dashboard's own origin (`CORS_ALLOWED_ORIGINS`, set by Terraform).

## What each route returns today

| Route | Data |
|---|---|
| `/api/live` | Devices heard from in the last 60 s (`live_state`), with the last 2 minutes of public track, `roughnessNow`, `msdvSoFar` and the latest MISC rating. A device is hidden until its track has left the start zone, whenever it is back inside it, and as soon as the trip has ended (its position is then its endpoint). |
| `/api/sessions`, `/api/sessions/{id}`, `/api/quality` | Built from `sessions`, `track_points`, `labels`, `events` and `ingest_batches`. Missing context gets the defaults the dashboard expects. Fills in distance (whole track length; `sessions.distance_m` once finalized), `msdvZ`/`msiPct`, public event counts, GPS accuracy, per-stream quality, `validFraction`/`invalidSeconds`/`processedAt` from the finalize job, and late and duplicate batch counts. |
| `/api/sessions/{id}/track` | 1 Hz track without the start zone, and without the end zone once the trip has ended (see Privacy). |
| `/api/sessions/{id}/series` | The 5 Hz chart series from the signal processing. |
| `/api/sessions/{id}/events` | Detected potholes, minus those in the private zones. |
| `/api/sessions/{id}/labels` | The trip's labels. |
| `/api/events` | Events of **aggregated** (finalized) trips only, minus those in the private zones. |
| `/api/overview` | Session counts, distance of aggregated trips, segment and pothole counts and the latest aggregation fit (`aggregation_fit`). |
| `/api/segments`, `/api/segments/{h3}` | `segments` + `segment_agg` (+ `segment_sickness`, `segment_observations`) from the aggregate job. Passes in a private zone are left out (the finalize job's flag and the read API's own rule). `/api/segments/{h3}` answers 404 for a cell without observations and 400 for anything else. |

Errors are always `{"error": "..."}`, with the CORS headers like any other answer (a 500 without them looks like a network error to the browser): 404 for an unknown session, segment or route, 400 for a bad query parameter (same allowed values as the mock), 503 when no database connection is free in time or a statement hits its timeout, 500 for anything else (logged with its stack trace). Times are `2026-11-21T09:12:03.512Z`; epoch milliseconds are integers.

`quality.streams` is the finalize job's (from the whole trip, `sessions.quality`) once a trip is finalized, under the dashboard's stream names (`deviceMotion` → `device_motion`). Before that it comes from the live batches (`ingest_batches.sample_counts`): rows, rate over the trip, and the longest pause between two batches carrying the stream. Gaps inside a batch aren't visible to the live path, `mag_raw` and `device` aren't counted by the processor, and an uploaded trip has `{}` until it is finalized.

Not computed yet: `detection`, speed bumps and rail joints. They're `null` (or empty) until something writes them.

## Privacy (plan §11)

A trip's positions stay in the database until it is 200 m away from where it started, and, once it has ended, from the last time it was 200 m away from where it ended (`app/queries.py`, applied in SQL by every route):

- Only fixes with `h_acc_m <= 50` count. Fixes without an accuracy or worse than that never anchor a zone and are never public, so a garage start or a cold GPS can't move the zone away from home.
- The start zone is a 200 m radius (geodesic) around the first accurate fix. The track is private until it leaves that radius (an accurate fix outside it, confirmed by the next accurate fix). This is a radius, not a path length: GPS jitter while parked can add up to hundreds of metres without the phone moving.
- The end zone is the same around the last accurate fix, from the last time the track was outside it. It applies once the trip has ended: status not `live`, or an end time, or a Stop message (`expected_batch_count`), or 15 minutes without batches, whichever comes first.
- Both are a prefix and a suffix: a trip that later passes its start again stays public there, so the track isn't punched full of holes. Events must be inside the public part of the track and also outside both radii.

## Performance

Every route runs a fixed number of queries, whatever the number of trips. The privacy windows use `LATERAL ... ORDER BY t LIMIT 1` on the `track_points` primary key, so they read the start and end of a track, not all of it; `/api/live` reads only the last 2 minutes of each live track. Track length (until a trip is finalized and has `sessions.distance_m`), GPS accuracy and live stream quality read a whole trip, so they are cached per trip until its `sessions.updated_at` or `status` changes (the processor bumps `updated_at` with every batch and session message; a job that rewrites a trip's track or batches must do the same).

| Env var | Default | |
|---|---|---|
| `READ_API_POOL_MAX_SIZE` | 5 | database connections per replica |
| `READ_API_POOL_TIMEOUT_S` | 10 | wait for a free connection, then 503 |
| `READ_API_STATEMENT_TIMEOUT_MS` | 10000 | the server cancels a slower statement (503) |

## Database login

On Azure, `PGUSER=reader` and each new connection gets a fresh Microsoft Entra token for the identity in `AZURE_CLIENT_ID`. The pool passes the token per connection (`app/db.py`), so it keeps working after the first token expires. Locally and in CI, `PGPASSWORD` is used.

## Tests

`tests/test_api.py` writes data through the stream processor's own `Store`, reads it back through the API against a real PostGIS, and checks every response's keys against the dashboard's TypeScript types. CI runs it (`.github/workflows/read-api-ci.yml`); locally it needs the docker-compose database:

```powershell
$env:PGHOST='localhost'; $env:PGPORT='5433'; $env:PGUSER='postgres'; $env:PGPASSWORD=$env:POSTGRES_PASSWORD
```
```powershell
cd services/read-api; python -m pytest -q tests
```

## Deploy

`deploy-services.yml` builds this image alongside the processor on every merge to `main`, updates the Container App, and waits until `GET /api/overview` answers 200 (which proves the Entra login as `reader` works). Then run **deploy-dashboard** from the Actions tab: it points the dashboard's `config.json` at this API and uploads the site.
