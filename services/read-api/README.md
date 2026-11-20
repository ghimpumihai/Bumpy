# Read API

The dashboard's only backend (plan §5, contract in [`dashboard/API.md`](../../dashboard/API.md)). FastAPI on port 8000, logged in to PostgreSQL as the read-only `reader` role. It runs as a Container App with public HTTPS ingress, and browsers may only call it from the dashboard's own origin (`CORS_ALLOWED_ORIGINS`, set by Terraform).

## What each route returns today

| Route | Data |
|---|---|
| `/api/live` | Devices heard from in the last 60 s (`live_state`), with the last 2 minutes of track and the latest MISC rating. A device is hidden during its trip's first 200 m, and as soon as the trip has ended (its position is then inside the last 200 m). |
| `/api/sessions`, `/api/sessions/{id}`, `/api/quality` | Built from `sessions`, `track_points` and `labels`. Missing context gets the defaults the dashboard expects. Distance is the length of the track; GPS accuracy, late and duplicate batch counts are filled in. |
| `/api/sessions/{id}/track` | 1 Hz track, minus the first 200 m, and minus the last 200 m once the trip has ended (plan §11). |
| `/api/sessions/{id}/labels` | The trip's labels. |
| `/api/overview` | Session counts; everything else is zero and `aggregation.method` is `none`. |
| `/api/sessions/{id}/series`, `/events`, `/api/segments`, `/api/segments/{h3}`, `/api/events` | Valid but empty: they come with the signal processing and aggregation. `/api/segments/{h3}` answers 404 for a valid cell and 400 for anything else. |

Errors are always `{"error": "..."}`: 404 for an unknown session, segment or route, 400 for a bad query parameter (same allowed values as the mock). Times are `2026-11-21T09:12:03.512Z`; epoch milliseconds are integers.

Not computed yet: `validFraction`, `msdvZ`/`msiPct`, per-stream rates, `roughnessNow`, `msdvSoFar`, `detection`. They're `null` (or empty) until the processing step writes them.

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
