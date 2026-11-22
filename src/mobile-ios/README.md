# Bumpy: iOS data-collection app (Xcode project `SensorRecorder`)

Native Swift/SwiftUI app (iOS 17+, built for an iPhone 14 Pro) that records every useful
sensor at the highest practical rate. It writes everything to local CSV files first, uploads
gzipped batches live to the Azure backend (when an API URL is set), and shows a live health dashboard. The requirements
are in [`decisions/01-initial-plan.md`](../../decisions/01-initial-plan.md) (backend:
[`02-infrastructure-plan.md`](../../decisions/02-infrastructure-plan.md)). No third-party dependencies.

## Run it on the iPhone

1. Open `src/mobile-ios/SensorRecorder.xcodeproj` in Xcode (16 or newer).
2. Target **SensorRecorder** → *Signing & Capabilities* → pick your **Personal Team**.
   If Xcode says the bundle id is taken, change `com.chuds.sensorrecorder` to something unique.
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → On** (reboot), plug it in
   and press Run. The first time, trust the developer certificate under
   *Settings → General → VPN & Device Management*.
4. Free provisioning expires after 7 days: just run it from Xcode again. Plan the drive inside that window.
5. **For the drive itself:** ⌘R builds an optimized **Release** build. After it launches, press
   Stop in Xcode, unplug, and start the app **from the home screen**. A debugger-attached app can be
   killed when the cable or wireless-debug link drops.

On first use the preflight asks for Motion & Fitness and Location (choose **Precise**). The app never
uses the microphone (D48) or the camera (no mount photo since D51).
Turn the ring/silent switch **off silent**, so the problem alert sound is audible (haptics work either way).

## Using it (operator)

Three screens (D51): **Start** → **Recording** → **Recap**. Lay the phone flat, screen up, and tap
**Start trip**. The preflight checks run silently; only a failing one shows, as one red line with a
fix, and starting anyway asks for a confirm (recorded as an override). While recording the screen
shows a timer and one status line (red while something is wrong, "GPS back · 12 s gap" for a few
seconds after GPS recovers). Hold **Hold to end trip** for 2 s. The recap shows data quality (share
of the trip with motion and GPS data) and how much of the trip reached the cloud: only parts the
backend accepted count, and every 2 s window left out of the live upload (upload off for part of the
trip, a full disk) and the Stop copy count too, so 100 % means the cloud has the whole trip. When a
part will never arrive by itself, the recap says so in amber and asks for the laptop upload. Every trip is
recorded as a car; there are no labels or sickness prompts. Results are on the web dashboard.

The menu (top left) holds **Web app** and **Settings**: server address, device key and Test
connection, with how many trips are still waiting to upload, and **Retry failed uploads (N)** while
the server has rejected parts (they wait in `upload_failed/`). The dashboard link appears once its
address is set, for now with the launch argument `-dashboard.baseURL <url>`.

The look follows the redesign mock-up: the dashboard's neutral palette, an ink-black accent and the
dashboard's typeface, Geist (`SensorRecorder/Resources/Fonts/Geist-Variable.ttf`, SIL Open Font
License in `Geist-OFL.txt`, registered through `UIAppFonts`; `Theme.font` sets its weight axis).

### Finding the Device ID

A device key works only under this phone's Device ID, a UUID kept in the Keychain. No screen shows it
since D51. Either:
- record a short trip (upload may be off) and read `deviceId` in its `session.json`, in the Files app
  or over USB; or
- with any valid key entered, run **Test connection**: the 403's reason, in the ingest function's logs
  (Application Insights), names the Device ID the phone sent.

## What gets written

`Documents/sessions/<UTC start>_<shortId>/` is visible in the **Files app** and in Finder over USB
(`UIFileSharingEnabled`): that is how a session is copied off the phone (there is no in-app export).

| File | Content |
|---|---|
| `session.json` | metadata (spec §3.8). Rewritten at start, at stop (with `stats`), and on recovery |
| `clock.csv` | `t_up,t_utc_ms,source`. Anchors at `start`, every 10 s (`periodic`), `background`/`foreground`, `stop` |
| `device_motion.csv`, `accel_raw.csv`, `gyro_raw.csv`, `mag_raw.csv` | CoreMotion at 100 Hz (mag 50 Hz), native units |
| `location.csv`, `heading.csv` | CoreLocation. `t_up` is derived from the fix's UTC timestamp (its age at arrival). iOS's cached first fix is kept if it is at most 5 s older than the start, so `location.csv` can begin slightly before `startedAtUtc`. Older cached fixes are dropped (logged), and GPS stats count only fixes from the start. |
| `altimeter.csv`, `abs_altitude.csv` | CMAltimeter relative (kPa, m) and absolute altitude |
| `activity.csv` | CMMotionActivity (+ `start_utc_ms`) |
| `device.csv` | battery, thermal, Low Power Mode, free disk, network, every 5 s |
| `labels.csv` | `t_up,t_utc_ms,type,value,note`: header only since D51 (no label buttons) |
| `app_log.txt` | warnings, problems, permission state, interruptions, upload rejections (also those after Stop: the file can grow past the size in `session.json` stats) |
| `mount.jpg` | mount photo (older builds only: there is no setup form since D51) |

Every sensor CSV starts with `t_up` (seconds since boot, the CoreMotion clock, 6 decimals) and
`t_utc_ms` (`anchor_utc_ms + (t_up − anchor_up)·1000`, using the latest anchor). Lat/lon have 8
decimals, everything else 6. The `.` decimal separator is used regardless of phone locale.
NaN is written as an empty field. Location keeps iOS's native `-1` for invalid speed/course.

New trips write no labels (D51): `labels.csv` has only its header, `stats.labelsCount` is 0 and
batches carry an empty `labels` array. Folders from older builds may hold the old label `type`
values: `pothole`, `speed_bump`, `phone_moved`, `surface_start/surface_end`
(`cobblestones|rough_asphalt|smooth_asphalt|gravel|tram_rails`), `segment_start/segment_end`
(`winding|roundabout|stop_and_go|highway|idle`), `sync_tap`, `note`, and the MISC rating types
`sickness`, `sickness_prompt` and `sickness_missed` (D47: motion sickness is only the backend's
MSDV). `session.json` `stats.sicknessRatings/sicknessMissed` stay as 0.

**No audio (D48).** The app records no sound: no `audio_*.m4a`, `audio_segments.csv`,
`audio_level.csv` or `audio_start` clock rows, no `audioLevel` in upload batches, and no
`audioEnabled`, `requestedRatesHz.audioLevel` or `stats.audioFiles` in `session.json`. Folders and
`session.json` files from older builds may still have them; they load and are ignored.

### Deliberate deviations from the spec (and why)

- **No audio (D48), against spec §3.5 S1/S2:** nothing in the backend used it, and it was the
  project's biggest privacy cost.
- **Extra files/columns:** `abs_altitude.csv` (B2), `activity.csv … start_utc_ms`.
- **Nothing can stall or re-order the queue:** 5xx/408/429/network errors retry the same file in
  place (the backend's 503 means an outage, never a bad payload), so the Stop copy always follows
  the last batch. A file the queue can't send at all (a Files-app copy with a changed name, an
  unreadable file) is moved to `upload_failed/`; a sent file that can't be deleted is not re-sent.
  After Stop the app asks iOS for background time until the queue is empty. Upload batches are queued only while an API URL is set (spec §6: empty URL = upload disabled), so
  set the URL before the drive: live upload is the main path to the cloud (02 D32), and laptop
  upload of the session folder is the fallback. The session folder stays the local source of truth.
- **401/403 are retried with backoff** instead of moved to `upload_failed/`; otherwise a mistyped
  key would dump the whole queue. 408/429/5xx/network errors are retried; other 4xx go to
  `upload_failed/` (they stay there, on the phone and in the Files app, until **Retry failed uploads**
  in Settings moves them back into the queue, D55). A pasted API URL ending in
  `/api/ingest` is reduced to its base (the app appends that path itself).
- **The upload test is a probe POST**, because the backend has no `/api/health` route.
  - The app sends `{"probe":true,"deviceId":"<Device ID>"}` (gzipped, with the device key and
    `x-probe: 1`) to `/api/ingest`.
  - The ingest function checks the key, then that the key is stored under this Device ID, then the
    schema. 400/422 therefore means "reachable and key accepted for this phone", and the probe is
    rejected, never stored. 401 means an unknown key; 403 means the key is stored under another
    Device ID (every batch would get 403 too); 404 means a wrong URL.
  - Plain `http://` is accepted only for local test servers (loopback, RFC 1918 IPs, `.local`), and
    redirects are never followed. On Wi-Fi, such a key *is* sniffable, so use a throwaway key for the
    mock server, never the real one. The real backend must be `https://`.
- **`clock.csv` rows are written from several queues** (periodic, lifecycle), so sort by `t_up`
  before use. Folders from builds before D48 also hold derived `audio_start` rows; they are not
  clock reads.
- **GPS/heading callbacks run on the main thread** (CLLocationManager delivers to the run loop that
  created it). At ~1 Hz with a cheap append, this is negligible.

## Upload contract (spec §6)

`POST {API}/api/ingest` with headers `Content-Type: application/json`, `Content-Encoding: gzip`,
`x-device-key`, `x-idempotency-key: <sessionId>:<batchSeq>`.

The body is the spec §6 JSON: schemaVersion 1, columnar arrays, `t` relative to `t0Up`, values
rounded to 6 decimals (lat/lon 8). The backend accepts only finite numbers, so a NaN/∞ never
reaches a batch: fields where iOS uses `-1` for invalid (speed, course, accuracies, battery) get
`-1` (a fix with a non-finite altitude keeps `alt` 0 and `vAcc` `-1`), any other sample with a
non-finite value is left out of the batch (the CSV keeps the row with an empty field); a non-finite
`t0UtcMs` or activity `startUtcMs` is sent as 0. For the hackathon rule ("JSON payload with device ID, event type, value,
unit, and UTC timestamp") it adds these optional, additive fields:
- `eventType: "sensor_batch"` and `source: "live"`;
- `t0UtcMs`, so a sample's UTC time is `t0UtcMs + t[i]·1000`;
- `fieldUnits`, the unit of every field (the §6 `units` map is unchanged);
- `location[].isSimulated`;
- the **full dataset** (02 D32): `deviceMotion.roll/pitch/yaw`, `magRaw`,
  `heading`, `absAltitude`, `activity`, `location[].ellAlt/vAcc/courseAcc` and the full `device` status.

All of this is listed for the backend team in spec §6.2 (`decisions/01-initial-plan.md`).

Backend: please don't use pydantic `extra="forbid"` or a fixed `units` literal.

**Session metadata (spec §6.1):** `PUT {API}/api/ingest/sessions/{sessionId}`, with the gzipped
`session.json`.
- It is sent at Start, and at Stop with an added `batchCount`.
- It goes through the same disk queue, so the Start copy is sent before batch 0 and the Stop copy
  after the last batch. Queue files are named `<createdMs>_<sessionId>_meta-start|stop.json.gz`, next
  to `<createdMs>_<sessionId>_<seq>.json.gz` for batches.
- The idempotency key is `<sessionId>:meta-start|stop`.
- `batchSeq` is assigned only to batches actually queued, so `batchCount` tells the backend exactly
  which `0…batchCount-1` to expect. Windows recorded while upload was OFF don't consume a number;
  a batch whose enqueue failed (full disk) gets its number only when a later tick queues it.
- File names use a strictly increasing `createdMs`, so a wall-clock step can't re-order them.
- Batches are about 30–50 KB of JSON; a warning is logged above 180 KB (the function's limit is 200 KB).

One request at a time, oldest first, with backoff 1 → 30 s; 2xx/409 means done.
- **404 / 401 / 403** are retried; they mean a config error. Session metadata 404/405 (no PUT route,
  or a redeploy in progress) is tried 8 times (about 1.5 minutes), then set aside in
  `upload_failed/` so the batches can go.
- **Redirects** are refused.
- **5xx / 408 / 429** are retried in place, never re-ordered or set aside. The ingest function
  answers 503 only for its own outages (Event Hubs, storage, Key Vault, or device keys it could
  not reload for more than 6 h).
- **Other 4xx** (400 schema or range, 413 too large) go to `upload_failed/`.
- **Accepted parts are recorded (D55):** before a sent file is deleted, its batch number (or
  `meta-start|stop`) is appended to `Documents/upload_acked/<sessionId>.txt`. The recap and the
  delete guard read it, together with `stats.uploadWindowsNotQueued` in the local `session.json`
  (windows that never entered the queue; omitted when 0, never sent in the Stop copy).

The API URL and key are entered in **Settings** at runtime (key in the Keychain); nothing secret is
in the repo.

## Privacy

- No sound is recorded (D48). `tools/upload` still skips `*.m4a`, which folders from older builds hold.
- GPS traces and `people.raterName` are personal data. Use pseudonyms such as "R1" for raters.
  Sessions live in Documents: they are visible in the Files app and included in device backups.
- Sessions are deleted from the Files app (there is no in-app session list since D51). The device
  ID is per phone (Keychain, this-device-only). `AppModel.deleteSession` (no button yet) refuses a
  trip unless every batch and the Stop copy were accepted, nothing is queued or rejected and no
  window was left out of the live upload (D55).

## Robustness

- Writes are buffered and flushed every 0.5 s (fsync every ~10 s) on a background queue; a crash
  loses < 1 s. Files are append-only.
- On launch, sessions without `endedAtUtc` are marked `"recovered": true`, a torn last CSV line is
  trimmed, and stats are rebuilt from the files, with the duration measured from the session start.
- The UI-test data reset (`-uiTestingReset`) exists only in Simulator Debug builds, so it can never
  wipe sessions on the phone.
- Screen never locks while recording; Stop needs a 2 s hold; there is no pause.
- Background mode `location` (continuous updates, never paused) keeps recording alive if the app
  is backgrounded (WARN).
- Every warning rule of spec §7 is implemented in `Core/HealthEvaluator.swift`. New PROBLEMs
  trigger a haptic, a sound and an `app_log.txt` entry.
- The on-phone live estimates (no longer shown since D51) use the backend's definitions, so the phone and the web dashboard
  agree (`Recording/LiveSignals.swift`):
  - **Roughness now:** RMS of the 1–30 Hz band-passed vertical acceleration (the backend's filter
    coefficients), averaged exponentially over about 5 s.
  - **MSDV so far:** ISO 2631-1 Wf on 0.1 s block means, with the blocks on a fixed 10 Hz grid.
  - **Signs:** CoreMotion's `userAcceleration` is minus the phone's acceleration, so it is flipped:
    vertical is positive up, lateral sway positive to the vehicle's left.

## Code map

```
SensorRecorder/
  App/        AppModel (services, navigation), app entry, device/version info
  Core/       TimeBase (clock anchors), CSV formatting, SessionFiles (schemas + buffered writers),
              SessionMetadata, SessionStore (folders, recovery), StreamMonitor (rates/gaps),
              HealthEvaluator (warning rules)
  Sensors/    CoreMotion, CoreLocation, device health (the synthetic source is in the test target)
  Recording/  RecordingSession (wires everything to disk), RecordingController (8 Hz dashboard),
              PreflightModel, TripSummary + SessionVerdict (recap data quality),
              LiveSignals (plots, roughness, ISO 2631-1 Wf MSDV estimate)
  Upload/     IngestBatch + accumulator, gzip (Compression + CRC32), disk UploadQueue,
              TripCloudCopy (the recap's cloud share and the delete guard), settings
  UI/         SwiftUI screens (Start, Recording, Recap, menu, Settings) and Theme
  Resources/  Assets.xcassets (app icon), Fonts/Geist-Variable.ttf (+ its OFL licence)
```

## Tests

```bash
cd src/mobile-ios
SIM="iPhone 17 Pro"   # any iOS 17+ simulator
# optional, for the UI tests: grant permissions and give the simulator a GPS position
xcrun simctl boot "$SIM"; for p in location motion; do
  xcrun simctl privacy "$SIM" grant $p com.chuds.sensorrecorder; done
xcrun simctl location "$SIM" set 46.77121,23.62363
xcodebuild -project SensorRecorder.xcodeproj -scheme SensorRecorder \
  -destination "platform=iOS Simulator,name=$SIM" test
```

- **Unit tests** cover CSV formatting, schemas, the clock math, concurrent writers, periodic flush,
  gap/rate stats, every warning rule, session.json, crash recovery, gzip/CRC, the batch payload
  shape (non-finite values included), every upload-queue rule, the accepted-parts record, the
  recap's cloud share and the delete guard, the Wf filter response vs ISO values, and a full
  3-second recording that checks every file on disk.
- **UI tests** drive the real app: Start (override on the Simulator) → Recording → short tap
  doesn't stop → hold-to-stop → Recap → Done, kill-while-recording → relaunch → recovered, and
  Settings (upload off; no recording switch, Back returns to Start).
- **The Simulator has no motion or barometer hardware.** Motion and barometer show "n/a" there,
  preflight can't be all green (the UI tests use the recorded *override*), GPS comes from
  `simctl location`. **Real data needs the iPhone.** Unit
  tests use a test-only synthetic 100 Hz motion source to exercise the full pipeline.
- Upload batches from the UI tests go to `tools/mock_ingest_server.py` on `:8765` when it is
  running (`-upload.baseURL`).
- **CI** (`.github/workflows/ios-app.yml`, `macos-15` with the newest non-beta Xcode on the runner,
  on an iPhone simulator with the newest iOS runtime) runs the unit tests only (`-only-testing:SensorRecorderTests`, no
  UI tests), the unsigned Release device build (skipped on pull requests) and `tools/test_tools.py`
  (also on Ubuntu). It runs on pushes to `main`/`staging` and on pull requests that touch
  `src/mobile-ios/` (Markdown changes excluded).

### Tools (`tools/`)

- `quick_check.py <session_folder>`: dry-run verifier (spec §10). Stdlib only.
- `mock_ingest_server.py`: local stand-in for the Azure ingest function (same check order, strict schema,
  200 for duplicates by default). It listens on loopback by default (Simulator). For the phone, run it
  with `--host 0.0.0.0 --key <throwaway>` and set the app's URL to `http://<mac-ip>:<port>`; the phone
  asks for Local Network permission the first time.
- `test_tools.py`: tests for both tools. It includes cross-language contract tests:
  - a batch and a Stop copy written by the app's real encoder
    (`tools/fixtures/ingest_batch_v1.json.gz`, `session_meta_stop_v1.json.gz`) must be accepted
    by the mock backend;
  - the CSV headers in `tools/fixtures/csv_headers.json` must match `quick_check.py`.
- The Swift tests compare against all three fixtures and never rewrite them. After a deliberate format
  change, regenerate with `TEST_RUNNER_REGENERATE_FIXTURES=1 xcodebuild … -only-testing:SensorRecorderTests/ContractFixtureTests test`.

**Before the real drive, do the mandatory dry run (spec §10).** Record 5–10 min on the real
phone, copy its folder off (Files app or Finder over USB), and run `python3 tools/quick_check.py <folder>`.
