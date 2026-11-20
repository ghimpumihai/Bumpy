# Dashboard — Road & Ride

Web dashboard of the Codelap 2026 project (plan: [02-infrastructure-plan.md](../decisions/02-infrastructure-plan.md)
§5 "Dashboard", §15). React + Vite + MapLibre (OpenFreeMap tiles) + uPlot, hosted as static files on
Azure Static Web Apps, reading the **read API** ([API.md](API.md)).

The backend pipeline is not deployed yet, so the dashboard ships with an in-browser **mock backend**
that implements the same API with generated sessions on real Cluj-Napoca streets (cars, bus 35, tram 101,
a winding hill road; potholes, speed bumps, cobblestones; a live car and a live replay). Every mock
session is labelled **Mock**. As soon as `config.json` has an `apiBase`, real data is shown instead.

## Run it

```bash
cd dashboard
npm ci
npm run dev            # http://localhost:5173 — mock data
VITE_API_BASE=http://localhost:8000 npm run dev   # against a local read API
npm run build          # static site in dist/
```

Data source precedence: `?mock=1` / `?mock=0` in the URL → the browser override from the
**Mock data / Read API** button in the header → `VITE_DATA_SOURCE` → `config.json` `apiBase` → mock.

## Screens

| Route | What it shows |
|---|---|
| `/` | Aggregated map: H3 road segments coloured by normalized roughness (ISO 2631-1 comfort bands) or by predicted motion sickness, detected events, crowd-confirmed potholes, per-vehicle filter, segment details |
| `/sessions` | Every session: vehicle, source (uploaded / live / replay), quality, whether it counts in the map and why not |
| `/sessions/{id}` | One trip: track coloured by speed, events, synchronized charts (road band, sway, speed, MSDV + MISC ratings), detection precision/recall vs. taps, prediction vs. ratings, context, data-quality panel |
| `/live` | Phones and replays streaming right now (polled every 2 s): moving markers, recent track, speed, roughness, MSDV, battery, staleness |
| `/quality` | Data-quality panel of every session: rates, gaps, GPS accuracy, valid share, invalid windows, rejected/late/duplicate live batches |
| `/method` | How the metrics are computed, with the current cross-vehicle fit (β, vehicle factors) |

## Checks

```bash
npm run check      # typecheck + oxlint + depcruise (no import cycles) + unit tests
npm run test:e2e   # Playwright against the production build: smoke tests on every route
                   # + axe-core WCAG 2.1 AA scan of every route in light and dark mode
```

Conventions are in [CLAUDE.md](CLAUDE.md).
