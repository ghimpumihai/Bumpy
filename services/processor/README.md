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

Signal processing (roughness, potholes, motion-sickness dose, H3 segments, chart series) is not in yet: `roughness_now` and `msdv_so_far` stay `null`.

## Database logins

On Azure there is no password: `PGUSER` is the role name and the password is an Entra token for the identity in `AZURE_CLIENT_ID`, requested when a connection opens. Locally and in CI, `AZURE_CLIENT_ID` isn't set and the throwaway PostGIS uses trust login on localhost, so no password exists anywhere (see `docker-compose.yml`).

## Run locally

```powershell
docker compose up -d db
```
```powershell
cd services/processor; $env:PGHOST='localhost'; $env:PGPORT='5433'; $env:PGUSER='postgres'; $env:PGDATABASE='roadride'
```
```powershell
$env:RUN_MODE='migrate'; python -m roadride
```
```powershell
python -m pytest -q tests
```

Without `PGHOST`, the database tests are skipped and only the unit tests run.

## Deploy

`.github/workflows/deploy-services.yml` runs on every merge to `main` that touches `services/processor/` or `db/`. It builds the image, pushes it to ACR, runs the migrate job and waits for it to succeed, then updates the processor. It needs two more repo variables besides the ingest ones: `ACR_NAME` and `RESOURCE_GROUP`.
