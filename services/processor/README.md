# Processor

One Python package and one Docker image for everything that needs the private database (plan §5). `RUN_MODE`, set per app or job by Terraform, picks the role:

| `RUN_MODE` | Runs as | What it does |
|---|---|---|
| `stream` | container app `ca-roadride-processor`, DB user `writer` | Reads Event Hubs and writes the live tables |
| `migrate` | job `caj-roadride-migrate`, DB user `migrator` (Entra admin) | Applies `db/migrations/*.sql`, creates the Entra roles `writer` / `reader`, grants rights |
| `finalize`, `aggregate` | jobs | Not implemented yet (they come with the signal processing) |

## Stream processor

For every message from the ingest function (partition key = device, so each phone's messages arrive in order):

- **`kind=session`** (`session.json` at Start and Stop): creates or updates the trip with its context (vehicle, mount, people). The Stop copy sets `ended_at` and `expected_batch_count`; a Start copy that arrives after the Stop copy is ignored.
- **`kind=batch`**: records the batch in `ingest_batches`, where `(session_id, batch_seq)` is unique, so a repeat is counted as a duplicate and ignored. It also stores every GPS fix in `track_points` and the labels in `labels`, and updates `live_state` for the device (position, speed, battery, sample time and arrival time).
  - A batch older than one already processed is marked **late**: stored, but it doesn't move the live position.
  - A batch with no fix keeps the previous position of the same trip.
- **Trip end**: once the Stop copy is in and every batch below `batchCount` has arrived, the trip goes from `live` to `processing`. Putting "session ready" on the Service Bus queue comes with the finalize job.
- **`exclusion_reasons` / `include_in_agg`**: refreshed after every message, following the rules in `dashboard/API.md`.

Every batch of events from one partition is written in **one transaction together with the partition's checkpoint** (`stream_checkpoints`), so a restart continues exactly where it stopped. A bad event is skipped inside a savepoint and logged. If the database stays unreachable after a reconnect, the process exits and Container Apps restarts it from the last checkpoint.

Each committed batch logs one line with the partition, the event count, the sequence number, `lag_s` (now minus the time Event Hubs received the last event) and the outcomes.

## Signal processing (`roadride/dsp.py`)

Each new, in-order batch runs through the trip's pipeline (plan §9):

- **Vertical acceleration:** user acceleration projected on "up" (minus the gravity direction), in m/s², resampled onto a uniform 100 Hz grid.
- **Roughness:** 1–30 Hz band-pass. `roughness_now` on the live view is its RMS over roughly the last 5 s.
- **Motion sickness:** ISO 2631-1 **Wf** applied at 20 Hz after low-pass and decimation. MSDV = (∫a_w² dt)^½ is accumulated over the whole trip: `msdv_so_far` live, `sessions.msdv_z`, and `msdv` in the series.
- **Potholes:** band-passed vertical above 5 m/s², only above 15 km/h, the peak within 0.3 s, at most one per second. Position comes from the nearest GPS fix. They're written to `events`.
- **Chart series:** `session_series` at 5 Hz, with vertical (the largest value of each 0.2 s window), lateral/longitudinal and speed.
- **Forward axis:** learned from GPS speed changes, so lateral/longitudinal stay 0 until about ten clear accelerations or brakings have been seen.

The pipeline keeps all its memory in a JSON state saved in `signal_state`, in the same transaction as its rows and the stream checkpoint. A test feeds a 10-minute signal whole and in random 1–3 s chunks (with a JSON round trip each time) and requires the same output, so the finalize job can reuse it unchanged. That equality assumes each GPS fix arrives in the batch that covers its time; a fix delivered a batch late only shifts the speed used for a second or so.

It runs on the phone's **uptime clock** (`t0Up + t`), which only moves forward during a recording. Each batch's UTC time comes from the app's latest clock anchor, which is refreshed periodically, so consecutive batches can overlap by a few milliseconds in UTC. Results are converted to UTC with each batch's own offset. Samples that overlap the previous batch are dropped rather than interleaved.

- **Late batches** skip the signal processing.
- **A missing batch or a time gap** restarts the filters (counted in `signal_state.gaps`) and keeps the dose.

**Provisional:** the pothole threshold and the forward-axis estimate haven't seen a real drive yet. Speed bumps, H3 segment observations, the finalize job and aggregation come next.

## Database logins

On Azure there is no password: `PGUSER` is the role name and the password is an Entra token for the identity in `AZURE_CLIENT_ID`, requested when a connection opens. Locally and in CI, `PGPASSWORD` is used instead: in CI it comes from the `POSTGRES_PASSWORD` repo secret, locally from your own environment (see `docker-compose.yml`). No password is in the repo.

## Run locally

```powershell
$env:POSTGRES_PASSWORD='<pick one>'; docker compose up -d db
```
```powershell
cd services/processor; $env:PGHOST='localhost'; $env:PGPORT='5433'; $env:PGUSER='postgres'; $env:PGPASSWORD=$env:POSTGRES_PASSWORD; $env:PGDATABASE='roadride'
```
```powershell
$env:RUN_MODE='migrate'; python -m roadride
```
```powershell
python -m pytest -q tests
```

Without `PGHOST` and `PGPASSWORD`, the database tests are skipped and only the unit tests run.

## Deploy

`.github/workflows/deploy-services.yml` runs on every merge to `main` that touches `services/processor/` or `db/`. It builds the image, pushes it to ACR, runs the migrate job and waits for it to succeed, then updates the processor. It needs two more repo variables besides the ingest ones: `ACR_NAME` and `RESOURCE_GROUP`.
