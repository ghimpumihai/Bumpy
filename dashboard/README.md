# Dashboard — Road & Ride

Web dashboard of the Codelap 2026 project (plan: [02-infrastructure-plan.md](../decisions/02-infrastructure-plan.md)
§5 "Dashboard", §15). React + Vite + MapLibre (CARTO Dark Matter base map) + uPlot, hosted as static files on
Azure Static Web Apps (`public/staticwebapp.config.json`: SPA fallback, caching, security headers), reading the **read API** ([API.md](API.md)).

**Real backend:** the read API ([`services/read-api/`](../services/read-api/README.md)) is deployed on Azure and
serves every route below. The site itself goes live with the manual **deploy-dashboard** workflow (Actions tab, runs
only from `main`), which writes `config.json` with the read API's address and uploads the build to Static Web Apps; it
last succeeded on 2026-11-21. Live, sessions, tracks, chart series, detected events and the motion-sickness dose come
from the live path; the Map page (heat lines, H3 segments, aggregation, events of finalized trips) and detection scores
fill in once the finalize and aggregate jobs have processed a trip.

For local work the dashboard also ships with an in-browser **mock backend**
that implements the same API with generated trips on real Cluj-Napoca streets (cars, bus 35, tram 101,
a winding hill road; potholes, speed bumps, cobblestones). It follows the live-first plan: most trips are
streamed and finalized, two are laptop uploads, a live car crosses a dead zone (stale, then catching up),
a replay streams bus 35, and one trip ends just before the page loads, so it moves from *Processing* to
the map. The **Data source** dialog (gear button in the dock) says when mock data is shown. As soon as
`config.json` has an `apiBase`, real data is shown instead.

## Run it

```bash
cd dashboard
npm ci
npm run dev            # http://localhost:5173 — mock data
VITE_API_BASE=http://localhost:8000 npm run dev   # against a local read API
npm run build          # static site in dist/
```

Data source precedence: `?mock=1` / `?mock=0` in the URL (remembered for the tab) → the browser override
from the **Data source** dialog → `VITE_API_BASE` (build time) → `config.json` `apiBase` → mock.

## Screens

| Route | What it shows |
|---|---|
| `/live` (start page) | The main screen (plan 02 §5): phones and replays sending data right now, polled every 2 s — moving markers, recent track, speed, roughness now, MSDV so far, and how far behind the phone the data is (or "catching up" after a dead zone). A card's locate button keeps the map centred on that phone until you drag, rotate or tilt the map, or click it again |
| `/map` | Strava-style heat map of the finalized trips: how many trips drove each road (from per-trip GPS lines), detected events, a list of the busiest roads, and a per-road panel (trips, roughness, potholes, sickness, the passes of finalized trips) |
| `/sessions` | Every trip and what it found: distance, duration, potholes, sickness and one status; a trip opens to its track, events, charts and data quality |
| `/sessions/{id}` | One trip: track coloured by speed, events, synchronized charts (road band, sway, speed, MSDV), detection precision/recall vs. taps, why it isn't counted in the map, data-quality panel |

## Checks

```bash
npm run check      # typecheck + oxlint + depcruise (no import cycles) + unit tests
npm run test:e2e   # Playwright against the production build, under the production CSP:
                   # projects `mock` and `api` (API mode over real HTTP, scripts/contract-api-server.mjs),
                   # smoke tests on every route, axe-core WCAG 2.1 AA in the dark theme (the only one, D52)

# Against the real read API (services/read-api) on a local PostGIS, seeded through the processor
# (e2e/real-api/seed.py resets the database, so its name must contain "e2e"). CI runs this as the
# `real-api` job of .github/workflows/dashboard-ci.yml, next to `npm run check` and `npm run test:e2e`:
docker run -d --rm --name pg-e2e -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=roadride_e2e -p 55440:5432 postgis/postgis:17-3.5
python3.12 -m venv /tmp/rr-e2e && /tmp/rr-e2e/bin/pip install -r ../services/read-api/requirements.txt -r ../services/processor/requirements.txt
PGHOST=localhost PGPORT=55440 PGUSER=postgres PGDATABASE=roadride_e2e \
  REAL_API_PYTHON=/tmp/rr-e2e/bin/python npx playwright test --project real-api
```

Conventions are in [CLAUDE.md](CLAUDE.md).
