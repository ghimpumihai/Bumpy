# Dashboard — Road & Ride

Web dashboard of the Codelap 2026 project (plan: [02-infrastructure-plan.md](../decisions/02-infrastructure-plan.md)
§5 "Dashboard", §15). React + Vite + MapLibre (OpenFreeMap tiles) + uPlot, hosted as static files on
Azure Static Web Apps (`public/staticwebapp.config.json`: SPA fallback, caching, security headers), reading the **read API** ([API.md](API.md)).

**Real backend:** the read API ([`services/read-api/`](../services/read-api/README.md)) is deployed on Azure and
serves every route below. The site itself goes live with the manual **deploy-dashboard** workflow (Actions tab), which
writes `config.json` with the read API's address and uploads the build to Static Web Apps. It hasn't been run yet. What
the real API fills in today: Live, sessions, quality, tracks, labels, chart series, potholes and the motion-sickness dose.
The Map page (H3 segments, aggregation), speed bumps and detection scores stay empty until the finalize job exists.

For local work the dashboard also ships with an in-browser **mock backend**
that implements the same API with generated trips on real Cluj-Napoca streets (cars, bus 35, tram 101,
a winding hill road; potholes, speed bumps, cobblestones). It follows the live-first plan: most trips are
streamed and finalized, two are laptop uploads, a live car crosses a dead zone (stale, then catching up),
a replay streams bus 35, and one trip ends just before the page loads, so it moves from *Processing* to
the map. Every mock trip is labelled **Mock**. As soon as `config.json` has an `apiBase`, real data is
shown instead.

## Run it

```bash
cd dashboard
npm ci
npm run dev            # http://localhost:5173 — mock data
VITE_API_BASE=http://localhost:8000 npm run dev   # against a local read API
npm run build          # static site in dist/
```

Data source precedence: `?mock=1` / `?mock=0` in the URL → the browser override from the
**Mock data / Read API** button in the header → `config.json` `apiBase` → mock.

## Screens

| Route | What it shows |
|---|---|
| `/live` (start page) | The main screen (plan 02 §5): phones and replays sending data right now, polled every 2 s — moving markers, recent track, speed, roughness now, MSDV so far, and how far behind the phone the data is (or "catching up" after a dead zone) |
| `/map` | Aggregated map of every finalized trip: H3 road segments coloured by normalized roughness (ISO 2631-1 comfort bands) or by predicted motion sickness, detected events, crowd-confirmed potholes, per-vehicle filter, segment details |
| `/sessions` | Every trip and what it found: distance, duration, potholes, sickness and one status; a trip opens to its track, events, charts and data quality |
| `/sessions/{id}` | One trip: track coloured by speed, events, synchronized charts (road band, sway, speed, MSDV), detection precision/recall vs. taps, context, data-quality panel |

## Checks

```bash
npm run check      # typecheck + oxlint + depcruise (no import cycles) + unit tests
npm run test:e2e   # Playwright against the production build, under the production CSP:
                   # mock mode + API mode over real HTTP (scripts/contract-api-server.mjs),
                   # smoke tests on every route, axe-core WCAG 2.1 AA in light and dark mode

# Against the real read API (services/read-api) on a local PostGIS, seeded through the processor:
docker run -d --rm --name pg-e2e -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=roadride_e2e -p 55440:5432 postgis/postgis:17-3.5
python3.12 -m venv /tmp/rr-e2e && /tmp/rr-e2e/bin/pip install -r ../services/read-api/requirements.txt -r ../services/processor/requirements.txt
PGHOST=localhost PGPORT=55440 PGUSER=postgres PGDATABASE=roadride_e2e \
  REAL_API_PYTHON=/tmp/rr-e2e/bin/python npx playwright test --project real-api
```

Conventions are in [CLAUDE.md](CLAUDE.md).
