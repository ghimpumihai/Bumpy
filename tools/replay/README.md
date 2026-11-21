# Replay tool

Sends a recorded trip through the live path, as if a phone were driving it right now: ingest
function → Event Hubs → processor → database → read API → dashboard. Plan 02 §5.

Use it for:

- **The end-to-end test**, before a drive and after every deploy.
- **The demo** in a room without a car: the Live page shows the trip moving, with roughness, potholes
  and the motion-sickness dose updating.
- **Re-running a real trip** after a change to the signal processing, for example to tune the pothole
  threshold.

Python 3, standard library only.

## Run it

1. Copy the session folder off the phone (Files app or Finder over USB: the app has no export button
   since D51), or use a `.zip` of it.
2. Create a key just for replays (once):

   ```powershell
   .\infra\scripts\add-device-key.ps1 -DeviceId replay
   ```

   Each key may only send as the device it was stored under. The replay key (stored as `replay` or
   `replay-<anything>`) may send any `replay-…` device ID, never a phone's. A phone's own key also
   works for replaying that phone's trips (`replay-<its device ID>`, the default). Anything else
   gets `403` and the replay stops.

3. Replay:

   ```powershell
   $env:REPLAY_DEVICE_KEY = "<the key>"
   $env:REPLAY_API_URL = "https://<ingest function>.azurewebsites.net"
   python tools/replay/replay.py <session folder or .zip>
   ```

   On macOS or Linux, run step 2 in `pwsh` (`brew install --cask powershell`) as
   `./infra/scripts/add-device-key.ps1 -DeviceId replay`, then in bash or zsh:

   ```bash
   export REPLAY_DEVICE_KEY='<the key>'
   export REPLAY_API_URL='https://<ingest function>.azurewebsites.net'
   python3 tools/replay/replay.py <session folder or .zip>
   ```

   `REPLAY_API_URL` is `ingest_base_url` from `./infra/tf.ps1 output`: the function's host with no path,
   the same value as in the app. A URL that already ends in `/api/ingest` works too (the tool strips it).

| Option | What it does |
|---|---|
| `--speed 4` | 4× faster (`0` = as fast as possible). Default is real time. |
| `--from 600 --duration 300` | Replay only minutes 10–15 of the trip. |
| `--device-id <id>` | Use your own device ID. The default is `replay-<the phone's deviceId>`, which gives the replay its own marker on the Live page. |
| `--no-stop` | Don't send the Stop metadata. Tests a trip that ends in silence. |
| `--dry-run <dir>` | Write the gzip bodies to `<dir>` and send nothing. |

**Ctrl+C** stops the replay and closes the trip: the Stop metadata is sent with the batches that
went out, so the trip doesn't stay "Recording".

## What it sends

The same requests as the app (spec §6, §6.1): `PUT /api/ingest/sessions/{id}` with `session.json` at
Start, then one `POST /api/ingest` per 2-second window, then the Stop copy with `batchCount`. Errors
are handled like the app's queue: network errors, `429` and `5xx` are retried with backoff from
1 s up to 30 s. `401`/`403` (bad key), `404` (wrong URL) or any other `4xx` stop the replay with
the server's reason.

The replay is a separate trip from the original:

- It gets a **new session ID**, `source: "replay"` and `replayOf: <original session ID>`. Replays are
  never counted in the aggregated map, so nothing is counted twice.
- **Every UTC time is moved** so the trip runs now. The phone's uptime clock (`t_up`, `t0Up`) stays as
  recorded.
- **Faster than real time**, the trip is placed so it ends when its last batch is sent. No timestamp
  is ever in the future (the backend keeps the newest position per device), so a fast replay looks
  like a phone catching up after a dead zone.
- Batches are rebuilt from the CSV files: `device_motion`, `accel_raw`, `gyro_raw`, `altimeter`,
  `location`, `labels`, and `device` for battery and thermal state. Samples are windowed by `t_up`
  from `startUptimeSec`. Audio files in older session folders are ignored (D48). A torn last
  line from a crash is skipped.

## Tests

```bash
python3 -m pip install pytest
python3 -m pytest -q tools/replay
```

The tests build a session folder in the app's CSV format (`src/mobile-ios/tools/fixtures/csv_headers.json`).
They check every batch against the real ingest contract and the processor's parser, and send a whole
replay over HTTP through the real ingest handler, with one forced `503`. CI: `replay-ci`.
