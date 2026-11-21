# Processor

One Python package and one Docker image for everything that needs the private database (plan §5). `RUN_MODE`, set per app or job by Terraform, picks the role:

| `RUN_MODE` | Runs as | What it does |
|---|---|---|
| `stream` | container app `ca-roadride-processor`, DB user `writer` | Reads Event Hubs and writes the live tables |
| `migrate` | job `caj-roadride-migrate`, DB user `migrator` (Entra admin) | Applies `db/migrations/*.sql`, creates the Entra roles `writer` / `reader`, grants rights |
| `finalize` | job `caj-roadride-finalize`, started by the `session-ready` queue, DB user `writer` | Rebuilds a finished trip from the raw archive or a laptop upload, writes Parquet, replaces its live results, writes segment passes and quality, then runs the aggregation |
| `aggregate` | job `caj-roadride-aggregate`, started by hand, DB user `writer` | Re-runs the aggregation alone (e.g. after the method changes) |

## Stream processor

For every message from the ingest function (partition key = device, so each phone's messages arrive in order):

- **`kind=session`** (`session.json` at Start and Stop): creates or updates the trip with its context (vehicle, mount, people). The Stop copy sets `ended_at` and `expected_batch_count`; a Start copy that arrives after the Stop copy is ignored.
- **`kind=batch`**: records the batch in `ingest_batches`, where `(session_id, batch_seq)` is unique, so a repeat is ignored. A repeat with a new `receivedAtUtc` is the phone sending it again and is counted in `duplicate_batches`; one with the same `receivedAtUtc` is the processor reading the same event twice (after a restart) and isn't counted. It also stores every GPS fix in `track_points` and the labels in `labels`, and updates `live_state` for the device (position, speed, battery, sample time and arrival time).
  - The batch itself (`ingest_batches` row, counters, track) is all or nothing. Labels, the signal processing and `live_state` each run in their own savepoint: a bad value in one of them (say a NUL character in a label note) drops only that part, logged and counted as `dropped_<part>`, so the trip can still complete.
  - A batch older than one already processed is marked **late**: stored, but it doesn't move the live position.
  - A batch with no fix keeps the previous position of the same trip.
- **Trip end**: once the Stop copy is in and every batch below `batchCount` has arrived, the trip goes from `live` to `processing`. A trip with no batch for 15 minutes is closed the same way, as `incomplete`.
- **Session ready** (`roadride/ready.py`): a background thread puts `{"sessionId": ...}` on the `session-ready` queue for every `processing` trip, after the transaction that ended it commits, and records it in `sessions.ready_sent_at`. It sweeps every minute (and right away when a trip ends), so a send lost in a crash is retried; a trip still `processing` 45 minutes after its message gets it again.
- New data for a trip that already ended (a batch from the backlog after the 15-minute close, or a Stop copy that came late) reopens it: back to `processing` with `ready_sent_at` cleared, so it is finalized again with everything. A trip whose message is dead-lettered is parked (`ready_sent_at = infinity`) instead of being resent forever.
- **`exclusion_reasons` / `include_in_agg`**: refreshed after every message, following the rules in `dashboard/API.md`.

Every batch of events from one partition is written in **one transaction together with the partition's checkpoint** (`stream_checkpoints`), so a restart continues exactly where it stopped. After the commit the SDK's in-memory checkpoint moves too, so a partition the SDK closes and claims again after an error resumes there, not at the start-up position.

- **A bad event is skipped** inside a savepoint, logged and counted as `skipped`; the other events and the checkpoint still commit. That includes database errors that psycopg reports as `OperationalError` but that would fail the same way on every retry (index row too large, disk full, timeouts). Deadlocks and serialization failures are retried up to three times first.
- **Only a lost connection is retried** (broken connection, SQLSTATE class `08`, `57P01`–`57P03`, or a failed connect or Entra token): once on a fresh connection, then the process exits and Container Apps restarts it from the last checkpoint.
- **On start**, each saved sequence number is checked against the event hub. If the hub was recreated (Terraform replaces it when `partition_count` changes, and its numbers restart at 0) or the next events have expired, the processor logs an error and reads from the earliest event kept instead of skipping everything up to the old number.
- **One thread** serves all partitions in turn (the SDK's synchronous client). A partition's events are handed over once 100 are waiting or a second after the last call, so an event can wait about a second before it's written: within the 10 s budget from phone to screen.

Each committed batch logs one line with the partition, the event count, the sequence number, `lag_s` (now minus the time Event Hubs received the last event) and the outcomes; the same values are separate fields in Application Insights.

| Setting | Default | |
|---|---|---|
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | unset | set by Terraform: logs of the `roadride` loggers and the metric `roadride.processor.lag` (seconds per partition, 0 when caught up; it keeps rising if the processor stalls) go to Application Insights. Tracing stays off, to keep the workspace under its daily cap. Unset, nothing is exported. |

## Signal processing (`roadride/dsp.py`)

Each new, in-order batch runs through the trip's pipeline (plan §9):

- **Vertical acceleration:** user acceleration projected on "up" (minus the gravity direction), in m/s², resampled onto a uniform 100 Hz grid.
- **Roughness:** 1–30 Hz band-pass. `roughness_now` on the live view is its RMS over roughly the last 5 s.
- **Motion sickness:** ISO 2631-1 **Wf** applied at 20 Hz after low-pass and decimation. MSDV = (∫a_w² dt)^½ is accumulated over the whole trip: `msdv_so_far` live, `sessions.msdv_z`, and `msdv` in the series.
- **Potholes:** band-passed vertical above 5 m/s², only above 15 km/h, the peak within 0.3 s, at most one per second. Position comes from the nearest GPS fix. They're written to `events` 2.5 s after the jolt, once no speed bump can cover them any more.
- **Speed bumps:** a double peak in the vehicle's pitch rate (the rotation rate about the lateral axis, 0.5–5 Hz): nose up above 0.15 rad/s as the front axle climbs, then nose down as the rear axle climbs, one wheelbase (2–7 m, car to bus or tram) apart at the GPS speed, between 5 and 40 km/h. Peaks longer than 0.5 s (a hill crest, a slow turn) don't count. The bump's jolts aren't reported as potholes. Pitch needs the forward axis, so there are no speed bumps until it is known.
- **Chart series:** `session_series` at 5 Hz, with vertical (the largest value of each 0.2 s window), lateral/longitudinal and speed.
- **Forward axis:** learned from GPS speed changes, so lateral/longitudinal stay 0 until about ten clear accelerations or brakings have been seen.

The pipeline keeps all its memory in a JSON state saved in `signal_state`, in the same transaction as its rows and the stream checkpoint. A test feeds a 10-minute signal whole and in random 1–3 s chunks (with a JSON round trip each time) and requires the same output, so the finalize job can reuse it unchanged. That equality assumes each GPS fix arrives in the batch that covers its time; a fix delivered a batch late only shifts the speed used for a second or so.

It runs on the phone's **uptime clock** (`t0Up + t`), which only moves forward during a recording. Each batch's UTC time comes from the app's latest clock anchor, which is refreshed periodically, so consecutive batches can overlap by a few milliseconds in UTC. Results are converted to UTC with each batch's own offset. Samples that overlap the previous batch are dropped rather than interleaved.

- **Late batches** skip the signal processing.
- **A missing batch or a time gap** restarts the filters (counted in `signal_state.gaps`) and keeps the dose. A gap is a hole of more than 0.25 s in the motion samples, between two batches or inside one (CoreMotion can stall for a moment): the samples on each side are never interpolated across it.

Each series window also carries the RMS of the band-passed vertical and its share of the dose (`rough_rms`, `dose_inc`); they aren't stored in `session_series`, but the finalize job builds segment passes from them.

**Provisional:** the pothole and speed-bump thresholds and the forward-axis estimate haven't seen a real drive yet. The pipeline's state of a trip in progress during the deploy that added the rotation rate is upgraded in place (no rotation channel yet: zero for the first interpolated sample).

## Finalize job (`roadride/finalize.py`)

KEDA starts one execution per message on `session-ready`; each execution handles up to 20 messages or 20 minutes, renewing the message lock while it works. For a trip it:

1. Reads `lake/raw/session=<id>/` (every accepted batch and both copies of `session.json`), 16 downloads at a time. If the trip has a complete laptop upload (`sessions/<id>/_complete.json`, see below), it reads that instead, for both kinds of message.
2. Runs the same pipeline over the whole trip, batch by batch in sequence order: late batches count, and the filters restart only at a missing batch. A cleanly streamed trip gives exactly the live series, events and MSDV (a test checks this).
3. Writes the trip as Parquet (below).
4. Releases the potholes the pipeline still held back at the end of the trip, runs the quality checks below, drops events inside "phone handled" windows and scores the rest against the manual taps.
5. In one transaction: re-applies the session metadata, fills in any missing track points and labels, replaces `session_series`, `events` (with `matched_label`) and `segment_observations`, and sets `status = complete`, `incomplete`, `msdv_z`, `quality_status`, `valid_fraction`, `quality`, `distance_m` and `finalized_at`. `include_in_agg` follows from the existing rules.
6. Rebuilds the aggregates, then completes the message.

Everything it writes is replaced per trip, so a repeated message is harmless. A failure abandons the message (Service Bus retries it, then dead-letters it after 5 tries). Messages it can't handle are dead-lettered with the reason: an unreadable body, a trip with no archive, or an upload that doesn't match its manifest.

**Laptop uploads (`roadride/upload.py`, plan §7 fallback).** [`tools/upload`](../../tools/upload/README.md) copies a session folder to `sessions/<sessionId>/` and writes `_complete.json` (every file's size and SHA-256) last; Event Grid's message for that file starts the job. The job uses the folder only if every listed file matches, then rebuilds the 2-second batches from the CSVs: windows of `t_up` from `startUptimeSec`, each with the UTC offset of its first row, as the phone and `tools/replay` build them. The same pipeline then runs over them (a test checks that the folder and the same trip replayed give the same series and events). An uploaded trip:
- **always wins** over the live archive, also when a backlog from the phone reopens the trip later, because it has every sample;
- replaces the trip's track points and labels (a live label's time can differ from the CSV's by a millisecond);
- keeps `source = live` if part of it streamed, else gets `source = upload`;
- has no batch count, so `incomplete` means the app crashed or never wrote `endedAtUtc`;
- gets per-stream quality for the extra CSVs too (accelerometer, gyro, magnetometer, barometer, audio level).

Its CSVs are read with pyarrow, streamed in blocks, with a forgiving fallback for unparseable values; torn last lines are dropped. A 3-hour trip needs about 0.6 GB.

**Parquet.** `lake/processed/session=<id>/motion.parquet` (100 Hz deviceMotion: `t_utc`, `t_up`, user acceleration, gravity and rotation rate in the phone's frame and units), `location.parquet` (every fix) and `series.parquet` (the 5 Hz results, with each window's roughness RMS and dose). zstd-compressed, overwritten on every finalize, written before the database commit, and listed in `quality.parquet`. A failed write (e.g. no write role on `lake`) is logged and recorded in `quality.parquetError`, and the trip is still finalized. Every trip at once: `duckdb -c "SELECT * FROM read_parquet('processed/*/series.parquet', hive_partitioning = 1)"`.

**Segment passes.** The 5 Hz series is split where the interpolated GPS position changes H3 cell (resolution 11, as the dashboard). A pass's roughness is the RMS over its moving windows (≥ 1 m/s, at least 3 of them), its speed is measured over the same windows, its a_w RMS is √(Σ dose / duration), and it counts the potholes inside it. Windows more than 10 s from a fix have no position and end the pass. Passes in the first or last 200 m are stored but flagged `in_privacy_zone` and never aggregated.

**Invalid windows (`roadride/quality.py`, plan §9 step 3, provisional thresholds).** Each 0.2 s series window can be invalid for one or more reasons, counted in `quality.invalidSeconds`:
- `phone_moved`: 5 s either side of a `phone_moved` tap, and 1 s before to 10 s after a `sync_tap` (the operator knocks on the phone, spec §5). Events there are dropped.
- `gravity_drift`: the 1 s mean gravity direction is more than 15° from the trip's typical one (the phone sagged or moved in its mount).
- `gyro_gps_mismatch`: between two fixes 0.5–3 s apart, both above 18 km/h, the gyro's yaw rate and the GPS course change differ by more than 0.2 rad/s.
- `gps_poor`: no fix within 2 s, or hAcc > 20 m.

`phone_moved` and `gravity_drift` windows don't count for a pass's roughness.

**Detection scores.** Potholes and speed bumps are scored against the `pothole` and `speed_bump` taps within ±1.5 s (`quality.detection`, API.md `DetectionMetrics`): a detection is a true positive if a tap of its type is that close, a tap is found if a detection is. `events.matched_label` says which detections matched.

**Quality (provisional rules).** `bad`: no motion, no GPS, or under half the expected 100 Hz motion samples. `degraded`: missing batches, filter restarts, under 90 % of the samples, mostly poor GPS (hAcc > 20 m), or more than 10 % of the trip invalid for one of `phone_moved`, `gravity_drift`, `gyro_gps_mismatch`. `ok` otherwise. `valid_fraction` = motion coverage × the share of windows that are valid for every reason.

## Aggregation (`roadride/aggregate.py`)

A port of the dashboard mock's method (`dashboard/src/mock/aggregate.ts`), with the same constants: roughness normalized by the fixed-effects fit `log r = segment + vehicle + β·log(v/10)` (car = reference, at least 30 observations in multi-pass segments, otherwise per-session percentiles); potholes crowd-confirmed per vehicle type (k of n passes above 15 km/h); sickness as duration-weighted a_w RMS over rigid-mount trips, split by seat and posture. Only `include_in_agg` trips and passes outside the privacy zones count. It rebuilds `segments`, `segment_agg`, `segment_sickness` and `aggregation_fit` in one transaction under an advisory lock, so overlapping finalize runs queue up.

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

`.github/workflows/deploy-services.yml` runs on every merge to `main` that touches `services/processor/` or `db/`. It builds the image, pushes it to ACR, runs the migrate job and waits for it to succeed, then points the finalize and aggregate jobs at the new image and updates the processor. It needs two more repo variables besides the ingest ones: `ACR_NAME` and `RESOURCE_GROUP`.
