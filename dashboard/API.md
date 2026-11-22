# Read API contract (dashboard ⇄ read API)

The dashboard reads everything from the **read API**, a small web service running as an Azure Container App
([02-infrastructure-plan.md](../decisions/02-infrastructure-plan.md) §5 "Read API (Container App)"). This file is
the contract between the two. The TypeScript source of truth is [`src/types/`](src/types); the mock
backend in [`src/mock/`](src/mock) implements every route below, so the dashboard can be developed and
demoed without Azure.

General rules:

- `GET` only, JSON responses (`application/json`). Map data is GeoJSON (RFC 7946, `[lon, lat]`). The
  dashboard rejects any other content type, and checks each response's envelope (e.g. `sessions` is an
  array) before using it, so a wrong API URL shows a clear error instead of breaking a page.
- Field names are camelCase. Timestamps are ISO-8601 UTC strings (`2026-11-21T09:12:03.512Z`) unless
  the field is documented as epoch milliseconds.
- Units: acceleration m/s² (gravity removed), speed m/s unless the name ends in `Kmh`, MSDV m/s^1.5.
- Missing values are `null`, never omitted.
- Errors: `4xx`/`5xx` with body `{"error": "human readable reason"}`. Unknown session/segment/route → `404`;
  invalid query parameter or H3 cell → `400`; database busy, unreachable or over its 10 s statement timeout
  → `503` (try again); anything else → `500`.
- CORS: only the origins in the read API's `CORS_ALLOWED_ORIGINS`, `GET` only. Terraform sets it to the
  dashboard's Static Web Apps origin (plus `extra_cors_origins`, empty by default); unset, no origin is allowed.
- **No privacy trim** (D40, replaces plan §11): tracks, events, segment observations and live positions are
  served whole, start and end included. `trimmedM` is always `0`. Only fixes less accurate than 50 m (or
  without an accuracy) are left out.
- **Aggregation rules** (plan §10): only finalized trips count: replays never, and a live trip only once it is finalized
  (until then its exclusion reason is `live_only`); sessions with
  `quality_status = 'bad'` are excluded; hand-held / non-rigid mounts are excluded from roughness and
  potholes; their sickness numbers count on the map (D41) and are flagged experimental on the trip page.

## Routes

| Route | Response type (`src/types/…`) | Notes |
|---|---|---|
| `GET /api/overview` | `Overview` (overview) | Headline counts + the aggregation fit (`method`, `beta`, `vehicleEffects`) |
| `GET /api/sessions?source=&vehicle=` | `SessionListResponse` (sessions) | Newest first. Optional filters `source` = `upload\|live\|replay`, `vehicle` = `car\|bus\|tram\|bike\|boat\|unknown` |
| `GET /api/sessions/{id}` | `SessionDetail` (sessions) | Summary + data-quality panel + detection scores + the calculated sickness dose (`sickness`: `msdv`, `msdvZ`, `msdvY`, `msiPct`; no passenger ratings, D47) |
| `GET /api/sessions/{id}/series` | `SessionSeries` (sessions) | Columnar `session_series`, about 5 Hz, `t` in epoch ms |
| `GET /api/sessions/{id}/track` | `SessionTrack` (sessions) | GeoJSON `Feature<LineString>`, 1 Hz, `properties.times` (epoch ms) and `speeds` (m/s) parallel to the coordinates |
| `GET /api/sessions/{id}/events` | `RoadEventCollection` (sessions) | GeoJSON points: potholes, speed bumps, rail joints |
| `GET /api/sessions/{id}/labels` | `SessionLabelsResponse` (sessions) | Rows of the app's `labels.csv`, without the `sickness` ratings of older app builds (D47) |
| `GET /api/segments?vehicle=all\|car\|bus\|tram` | `SegmentCollection` (segments) | One H3 cell polygon per segment with its `segment_agg` row for that vehicle filter. The cell is the backend's key; the dashboard draws only its centre |
| `GET /api/heat` | `HeatCollection` (segments) | One GeoJSON `MultiLineString` per aggregated trip (simplified to about 2 m, so a straight stretch keeps only a few points; cut at gaps longer than 10 s or about 200 m; pieces shorter than about 4 m, GPS jitter while parked, are dropped). The dashboard counts how many trips cover each pixel and colours the map from that (Strava-style heat map) |
| `GET /api/segments/{h3}` | `SegmentDetail` (segments) | Per-vehicle aggregates, sickness split by seat/posture, every pass |
| `GET /api/events?vehicle=all\|car\|bus\|tram&type=` | `RoadEventCollection` (sessions) | Detected events of aggregated sessions only; `vehicle` takes the same values as `/api/segments` (the dashboard always sends it), `type` is optional (`pothole\|speed_bump\|rail_joint`) |
| `GET /api/live` | `LiveResponse` (live) | `live_state` of devices whose newest batch the ingest function received in the last 60 s, with the last ~2 min of track, `receivedAt` (arrival of that batch; late batches don't move it), and `sessionStatus` (`live`, or `processing`/`complete` once the trip has ended). Since D40 a device is listed from its first position, and stays listed for up to 60 s after its last batch, so for up to 60 s after its trip ends. Polled every 2 s; `serverTime` lets the dashboard measure ages on the server's clock |
| `GET /api/quality` | `QualityListResponse` (sessions) | The data-quality panel for every session (the dashboard doesn't call it at the moment) |

The ingest routes (`POST /api/ingest`, and `PUT /api/ingest/sessions/{id}` from spec §6.1) belong to the ingest
function, on a different host, and are not used by the dashboard. There is no health route.

## Session status and exclusion reasons (plan §8, §10)

| `status` | Meaning |
|---|---|
| `live` | Recording: batches are still arriving through the live path. A trip that gets new data after it ended goes back to `live` and ends again by the same rules (D54) |
| `processing` | The trip ended (Stop received and every batch in, or 15 min without batches); the finalize job hasn't finished |
| `complete` | Finalized: rebuilt from the raw archive (or the uploaded folder) and aggregated |

`incomplete: true` marks a trip closed after 15 min without batches, without the app's Stop message or with
batches missing; it is still finalized, with its gaps marked. `source` is how the trip reached the cloud: `live` (streamed, the main path), `upload`
(laptop fallback) or `replay`.

`exclusionReasons` explain why a trip is (partly) kept out of the aggregated map: `replay`, `live_only`
(streamed, not finalized yet), `processing` (an upload not finalized yet), `bad_quality`,
`unknown_context` (session.json never arrived, spec §6.1), `not_rigid`, `handheld` (the last two exclude
it from roughness only).

## Live freshness (plan §5 "Dashboard")

For each live device the dashboard derives, on the server's clock:
- data age = now − `updatedAt` (sample time): the end-to-end delay to the screen (target < 10 s);
- silence = now − `receivedAt`: amber after 10 s, red after 30 s (a dead zone). A trip that ended stays
  listed for up to 60 s (above) and is shown as **trip ended** instead, since its silence is expected;
- transport delay = `receivedAt` − `updatedAt`: above 10 s while batches are arriving, the phone is
  sending a backlog after a dead zone, shown as **catching up** rather than live.

If the dashboard itself can't reach the read API (a failed poll, or no answer for 3 poll intervals), it
says so and shows each card's last data time, instead of reporting the phones as silent.

## Where each field comes from (plan §8)

| Dashboard field | Table / computation |
|---|---|
| `SessionSummary.*` context | `sessions`, from `session.json` |
| `isMock` | `session.json` → `syntheticSensors` (mock sessions generated for the pipeline) |
| `includeInAgg`, `exclusionReasons` | `sessions.include_in_agg` and the rule that set it |
| `msdv`, `msdvZ`, `msdvY`, `msiPct` | MSDV of the whole session (so far, while live). `msdvZ` is the vertical part (ISO 2631-1 Wf), `msdvY` the side-to-side part (Donohew & Griffin weighting; null for trips processed before D49), `msdv = √(msdvZ² + msdvY²)` the combined dose; `msiPct = msdv / 3`, ISO 2631-1's rule for vertical motion over 20 min to 6 h, applied to the combined dose (indicative for shorter trips) |
| `quality.*` | per-stream rows/rates/gaps, GPS accuracy, invalid windows, late/duplicate live batches (`rejectedBatches` is always `0`: a rejected batch never reaches the database). Per stream, the finalize job's whole-trip numbers where it has them, else the live batches' |
| `distanceM` | sum of the steps between fixes with a known accuracy ≤ 50 m, counting a step only when either end moves ≥ 1 m/s (or neither has a speed), so GPS jitter while parked adds nothing |
| `detection` | detections vs. manual taps within ±1.5 s. `truePositives`/`falsePositives` count detections (one with a tap of its type that close, or none), `falseNegatives` counts taps with no detection that close; `precision = TP / (TP + FP)` over detections, `recall` = found taps / all taps |
| `RoadEvent.magnitude` | m/s²: peak \|band-passed (1–30 Hz) vertical acceleration\| at the jolt (pothole, never below the 5 m/s² detection threshold) or at either axle (speed bump) |
| `SessionSeries` | `session_series` (≈ 5 Hz, one row per 0.2 s window, `t` its end): `aVert` (m/s², + up) the 1–30 Hz band-passed vertical with the largest \|value\| in the window; `aLat` (+ left) and `aLon` (+ forward), m/s², 2 Hz low-passed window means, 0 until the forward axis is learned; speed; combined MSDV so far |
| `SegmentAggregate` | `segment_agg` table, rebuilt by the aggregation step (segment × vehicle type, plus an `all` row) |
| `roughness` | `exp(mean(log r − vehicle effect − β·log(v / 10 m/s)))`: what a car would feel at 36 km/h. Only vehicles linked to the car through shared segments are fitted (D45); a segment driven only by others has `roughness: null` and `roughnessMethod: "percentile"` |
| `roughnessPctl` | mean per-session percentile of raw roughness (fallback when the model can't be fitted); ranked over the passes that count for roughness (≥ 2 m/s), ties share their average rank |
| `potholeHits / potholePasses / potholeConfirmed` | passes > 15 km/h with a detection; confirmed at ≥ k of n passes (per vehicle type) |
| `sicknessAwRms`, `msi1hPct` | `sqrt(Σ a_w²·dt / Σ dt)`, a_w² = a_wz² + a_wy² (vertical and lateral, D49), over the moving, valid time (speed ≥ 1 m/s, phone not handled and not shifted in its mount: `phone_moved`, `gravity_drift`; D45) of sessions with a known context (hand-held and non-rigid mounts included, D41); `msi1hPct = a_w·√3600 / 3`; `sicknessSessions` counts sessions with such time. `SegmentObservation.awRms` stays the whole pass, as measured |
| `LiveDevice` | `live_state` + the last positions of the live session; `receivedAt` is `live_state.received_at`, when the ingest function received the batch. `roughnessNow`: RMS of the 1–30 Hz band-passed vertical over about the last 5 s (exponential, τ = 5 s), m/s². `msdvSoFar`: combined MSDV so far (D49), m/s^1.5 |

Implementation note learned while building the mock: measure a segment pass's **speed over the same
samples as its roughness RMS** (i.e. moving samples only). Mixing stationary samples into the speed
biases the fitted β low (0.54 instead of 0.60 on the mock data).

## Hosting (Azure Static Web Apps)

`public/staticwebapp.config.json` makes client-side routes work on refresh (fallback to `index.html`),
serves `config.json` with `Cache-Control: no-store` and outside the fallback, caches `assets/*` for a
year, and sends the security headers (CSP: scripts only from the site, API and tiles over HTTPS only,
no framing). `vite preview` serves the same headers, so the e2e tests run under that CSP.

## Runtime configuration

The deployed site reads `/config.json` at startup: `{"apiBase": "https://<read-api>.<env>.northeurope.azurecontainerapps.io"}`.
The `deploy-dashboard.yml` workflow (called by the release, main only) writes this file just before uploading, with the
read API container app's address (`az containerapp show`), after checking that its `/api/overview` answers
JSON with a CORS header for the site's origin; the committed `public/config.json` stays empty. An empty `apiBase` (the
default in `public/config.json`) makes the dashboard use its built-in mock data. A missing, unreachable
(5 s timeout) or invalid `config.json` stops the dashboard with an error instead: a broken deploy must not
quietly show mock data.
