# Read API contract (dashboard ⇄ read API Lambda)

The dashboard reads everything from the **read API Lambda** behind API Gateway
([02-infrastructure-plan.md](../decisions/02-infrastructure-plan.md) §5 "Read API Lambda"). This file is
the contract between the two. The TypeScript source of truth is [`src/types/`](src/types); the mock
backend in [`src/mock/`](src/mock) implements every route below, so the dashboard can be developed and
demoed without AWS.

General rules:

- `GET` only, JSON responses (`application/json`). Map data is GeoJSON (RFC 7946, `[lon, lat]`).
- Field names are camelCase. Timestamps are ISO-8601 UTC strings (`2026-11-21T09:12:03.512Z`) unless
  the field is documented as epoch milliseconds.
- Units: acceleration m/s² (gravity removed), speed m/s unless the name ends in `Kmh`, MSDV m/s^1.5.
- Missing values are `null`, never omitted.
- Errors: `4xx`/`5xx` with body `{"error": "human readable reason"}`. Unknown session/segment → `404`;
  invalid query parameter → `400`.
- CORS: only the dashboard's CloudFront origin (plan §5).
- **Privacy** (plan §11): the API trims the first and last `PRIVACY_TRIM_M` (200 m) of every track, and
  drops events and segment observations inside that zone, before anything leaves the database.
- **Aggregation rules** (plan §10): replays and live-only sessions are never in aggregates; sessions with
  `quality_status = 'bad'` are excluded; hand-held / non-rigid mounts are excluded from roughness and
  potholes, and their sickness numbers are flagged experimental.

## Routes

| Route | Response type (`src/types/…`) | Notes |
|---|---|---|
| `GET /api/overview` | `Overview` (overview) | Headline counts + the aggregation fit (`method`, `beta`, `vehicleEffects`) |
| `GET /api/sessions?source=&vehicle=` | `SessionListResponse` (sessions) | Newest first. Optional filters `source` = `upload\|live\|replay`, `vehicle` = vehicle type |
| `GET /api/sessions/{id}` | `SessionDetail` (sessions) | Summary + data-quality panel + detection scores + sickness ratings |
| `GET /api/sessions/{id}/series` | `SessionSeries` (sessions) | Columnar `session_series`, about 5 Hz, `t` in epoch ms |
| `GET /api/sessions/{id}/track` | `SessionTrack` (sessions) | GeoJSON `Feature<LineString>`, 1 Hz, `properties.times` (epoch ms) and `speeds` (m/s) parallel to the coordinates |
| `GET /api/sessions/{id}/events` | `RoadEventCollection` (sessions) | GeoJSON points: potholes, speed bumps, rail joints |
| `GET /api/sessions/{id}/labels` | `SessionLabelsResponse` (sessions) | Rows of the app's `labels.csv` |
| `GET /api/segments?vehicle=all\|car\|bus\|tram` | `SegmentCollection` (segments) | One H3 hexagon polygon per segment with its `segment_agg` row for that vehicle filter |
| `GET /api/segments/{h3}` | `SegmentDetail` (segments) | Per-vehicle aggregates, sickness split by seat/posture, every pass |
| `GET /api/events?vehicle=&type=` | `RoadEventCollection` (sessions) | Detected events of aggregated sessions only |
| `GET /api/live` | `LiveResponse` (live) | `live_state` of devices that sent data in the last 60 s, with the last ~2 min of track. Polled every 2 s |
| `GET /api/quality` | `QualityListResponse` (sessions) | The data-quality panel for every session |

The ingest routes (`POST /api/ingest`, `GET /api/health`) belong to the ingest Lambda and are not used
by the dashboard.

## Where each field comes from (plan §8)

| Dashboard field | Table / computation |
|---|---|
| `SessionSummary.*` context | `sessions` (+ `vehicles`, `devices`), from `session.json` |
| `isMock` | `session.json` → `syntheticSensors` (mock sessions generated for the pipeline) |
| `includeInAgg`, `exclusionReasons` | `sessions.include_in_agg` and the rule that set it |
| `msdvZ`, `msiPct` | MSDV of the whole session (ISO 2631-1 Wf, vertical); `msiPct = msdvZ / 3` |
| `quality.*` | per-stream rows/rates/gaps, GPS accuracy, invalid windows, `rejected/late/duplicate` live batches |
| `detection` | detections vs. manual taps within ±1.5 s (precision, recall) |
| `SessionSeries` | `session_series` (≈ 5 Hz vertical/lateral/longitudinal acceleration, speed, MSDV so far) |
| `SegmentAggregate` | `segment_agg` materialized view (segment × vehicle type, plus an `all` row) |
| `roughness` | `exp(mean(log r − vehicle effect − β·log(v / 10 m/s)))`: what a car would feel at 36 km/h |
| `roughnessPctl` | mean per-session percentile of raw roughness (fallback when the model can't be fitted) |
| `potholeHits / potholePasses / potholeConfirmed` | passes > 15 km/h with a detection; confirmed at ≥ k of n passes (per vehicle type) |
| `sicknessAwRms`, `msi1hPct` | `sqrt(Σ a_w²·dt / Σ dt)` over rigid-mount sessions; `msi1hPct = a_w·√3600 / 3` |
| `LiveDevice` | `live_state` + the last positions of the live session |

Implementation note learned while building the mock: measure a segment pass's **speed over the same
samples as its roughness RMS** (i.e. moving samples only). Mixing stationary samples into the speed
biases the fitted β low (0.54 instead of 0.60 on the mock data).

## Runtime configuration

The deployed site reads `/config.json` at startup: `{"apiBase": "https://<api-id>.execute-api.eu-west-1.amazonaws.com"}`.
Infrastructure writes this file next to the site; CI must not overwrite it. An empty `apiBase` (the
default in `public/config.json`) makes the dashboard use its built-in mock data.
