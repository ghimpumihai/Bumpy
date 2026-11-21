# Sensor Recorder: iOS data-collection app

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

On first use the preflight asks for Motion & Fitness, Location (choose **Precise**) and Microphone.
Turn the ring/silent switch **off silent**, so the sickness-prompt sound is audible (haptics work either way).

## Using it (operator)

Sessions → **New session** → setup (pre-filled with your last values, plus a mount photo; for
**bus/tram** also the line number, seat, rater posture, and **audio recording defaults to OFF**) →
**Preflight** (must be all green; *Override* exists for emergencies and is recorded) →
**Recording dashboard** → hold **Stop** for 2 s → **Summary** (red rows = gaps > 1 s) →
**Export**. The full drive protocol is in the app (the **?** button) and in spec §9.

## What gets written

`Documents/sessions/<UTC start>_<shortId>/` is visible in the **Files app** and in Finder over USB
(`UIFileSharingEnabled`), so data can be copied off even without the Export button.

| File | Content |
|---|---|
| `session.json` | metadata (spec §3.8). Rewritten at start, at stop (with `stats`), and on recovery |
| `clock.csv` | `t_up,t_utc_ms,source`. Anchors at `start`, every 10 s (`periodic`), `background`/`foreground`, `stop`, plus one `audio_start` per audio segment |
| `device_motion.csv`, `accel_raw.csv`, `gyro_raw.csv`, `mag_raw.csv` | CoreMotion at 100 Hz (mag 50 Hz), native units |
| `location.csv`, `heading.csv` | CoreLocation. `t_up` is derived from the fix's UTC timestamp (its age at arrival). iOS's cached first fix is kept if it is at most 5 s older than the start, so `location.csv` can begin slightly before `startedAtUtc`. Older cached fixes are dropped (logged), and GPS stats count only fixes from the start. |
| `altimeter.csv`, `abs_altitude.csv` | CMAltimeter relative (kPa, m) and absolute altitude |
| `activity.csv` | CMMotionActivity (+ `start_utc_ms`) |
| `audio_000.m4a`, `audio_001.m4a`, … | AAC 48 kHz mono 64 kbps, in 5-minute segments |
| `audio_segments.csv` | `t_up,t_utc_ms,event,file`: start/stop/interrupted per segment |
| `audio_level.csv` | RMS and peak dBFS at 10 Hz |
| `device.csv` | battery, thermal, Low Power Mode, free disk, network, every 5 s |
| `labels.csv` | `t_up,t_utc_ms,type,value,note` (all human labels and sickness ratings) |
| `app_log.txt` | warnings, problems, permission state, interruptions, upload rejections |
| `mount.jpg` | mount photo |

Every sensor CSV starts with `t_up` (seconds since boot, the CoreMotion clock, 6 decimals) and
`t_utc_ms` (`anchor_utc_ms + (t_up − anchor_up)·1000`, using the latest anchor). Lat/lon have 8
decimals, everything else 6. The `.` decimal separator is used regardless of phone locale.
NaN is written as an empty field. Location keeps iOS's native `-1` for invalid speed/course.

Label `type` values: `pothole`, `speed_bump`, `phone_moved`, `surface_start/surface_end`
(`cobblestones|rough_asphalt|smooth_asphalt|gravel|tram_rails`, mutually exclusive),
`segment_start/segment_end` (`winding|roundabout|stop_and_go|highway|idle`, independent),
`sync_tap`, `note` (text in `note`), `sickness` (value 0–10, note `prompt`|`manual`),
`sickness_prompt`, `sickness_missed`. Open toggles are closed automatically at Stop
(note `auto at stop`).

### Deliberate deviations from the spec (and why)

- **Audio in 5-minute segments, not one `audio.m4a`.** An AAC/MP4 file is only readable once
  `stop()` writes its index, so a crash, a force-quit or a dead battery would destroy the entire
  drive's audio. Segments overlap at rotation (no gap), and each start time is logged, so
  segment *n* starts at the *n*-th `audio_start` row in `clock.csv`. After an interruption
  (phone call, Siri) a *new* segment starts, so every file maps linearly onto `t_up`.
- **Audio session `.playAndRecord` + mode `.measurement` + `.mixWithOthers`** (spec: `.record`).
  - Measurement mode still disables AGC and voice processing.
  - playAndRecord plus `allowHapticsAndSystemSoundsDuringRecording` is needed so the prompt and
    alert sounds and haptics work while recording (iOS mutes them otherwise).
  - Mixable means the session never stops navigation or music, and can restart while backgrounded.
  - Input is pinned to the built-in mic, so the car's Bluetooth hands-free can't take over.
- **Audio OFF mode (bus/tram, GDPR, spec §3.5).** When `audioEnabled` is false, no audio is ever
  written. `audio_level.csv` (S1) still comes from a live level meter (`AVAudioEngine` tap, numbers
  only). A stalled meter is a PROBLEM on the dashboard.
- **Extra files/columns:** `audio_segments.csv`, `abs_altitude.csv` (B2), `activity.csv … start_utc_ms`.
- **One poison batch can't block the queue:** after 5 server errors (5xx/408/429) for the same
  batch, it moves to the back of the queue. Network errors don't count, and nothing is deleted.
  Upload batches are queued only while an API URL is set (spec §6: empty URL = upload disabled), so
  set the URL before the drive: live upload is the main path to the cloud (02 D32), and laptop
  upload of the session folder is the fallback. The session folder stays the local source of truth.
- **401/403 are retried with backoff** instead of moved to `upload_failed/`; otherwise a mistyped
  key would dump the whole queue. 408/429/5xx/network errors are retried; other 4xx go to
  `upload_failed/` (Settings → *Move failed batches back to queue*).
- **The upload test is a probe POST**, because the backend has no `/api/health` route.
  - The app sends `{"probe":true}` (gzipped, with the device key and `x-probe: 1`) to `/api/ingest`.
  - The ingest function checks the key first, then the schema. 400/422 therefore means
    "reachable and key accepted", and the probe is rejected, never stored. 401/403 means the key
    was rejected; 404 means a wrong URL.
  - Plain `http://` is accepted only for local test servers (loopback, RFC 1918 IPs, `.local`), and
    redirects are never followed. On Wi-Fi, such a key *is* sniffable, so use a throwaway key for the
    mock server, never the real one. The real backend must be `https://`.
- **`clock.csv` rows are written from several queues** (periodic, lifecycle, `audio_start`), so
  sort by `t_up` before use. `audio_start` rows are derived from the current anchor; they are not
  separate clock reads.
- **GPS/heading callbacks run on the main thread** (CLLocationManager delivers to the run loop that
  created it). At ~1 Hz with a cheap append, this is negligible.

## Upload contract (spec §6)

`POST {API}/api/ingest` with headers `Content-Type: application/json`, `Content-Encoding: gzip`,
`x-device-key`, `x-idempotency-key: <sessionId>:<batchSeq>`.

The body is the spec §6 JSON: schemaVersion 1, columnar arrays, `t` relative to `t0Up`, values
rounded to 6 decimals. For the hackathon rule ("JSON payload with device ID, event type, value,
unit, and UTC timestamp") it adds these optional, additive fields:
- `eventType: "sensor_batch"` and `source: "live"`;
- `t0UtcMs`, so a sample's UTC time is `t0UtcMs + t[i]·1000`;
- `fieldUnits`, the unit of every field (the §6 `units` map is unchanged);
- `location[].isSimulated`;
- the **full dataset** (02 D32: only raw audio stays on the phone): `deviceMotion.roll/pitch/yaw`, `magRaw`,
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
  which `0…batchCount-1` to expect. Windows recorded while upload was OFF don't consume a number.
- Batches are about 30–50 KB of JSON; a warning is logged above 180 KB (the function's limit is 200 KB).

One request at a time, oldest first, with backoff 1 → 30 s; 2xx/409 means done.
- **404 / 401 / 403** are retried; they mean a config error.
- **Redirects** are refused.
- **A batch that keeps failing on the server** moves to the back of the queue.

The API URL and key are entered in **Settings** at runtime (key in the Keychain); nothing secret is
in the repo.

## Privacy

- Audio (`audio_*.m4a`) is never sent live. It is in the session folder and the export, so
  `tools/upload` should exclude `*.m4a` if audio must stay on the phone. On bus/tram, audio
  recording is OFF by default (level meter only).
- GPS traces and `people.raterName` are personal data. Use pseudonyms such as "R1" for raters.
  Sessions live in Documents: they are visible in the Files app and included in device backups.
- **Delete session** (session detail) removes the folder. It is refused while any of the
  session's batches are still queued for upload, so a trip leaves the phone only once it
  reached the cloud. The device ID is per phone (Keychain, this-device-only).

## Robustness

- Writes are buffered and flushed every 0.5 s (fsync every ~10 s) on a background queue; a crash
  loses < 1 s. Files are append-only.
- On launch, sessions without `endedAtUtc` are marked `"recovered": true`, a torn last CSV line is
  trimmed, and stats are rebuilt from the files, with the duration measured from the session start.
- The audio segment being recorded at a crash has no MP4 index and isn't playable. It is listed in
  `stats.audioFilesIncomplete` and in `app_log.txt`.
- The UI-test data reset (`-uiTestingReset`) exists only in Simulator Debug builds, so it can never
  wipe sessions on the phone.
- Screen never locks while recording; Stop needs a 2 s hold; there is no pause.
- Background modes `location` + `audio` keep recording alive if the app is backgrounded (WARN).
- Every warning rule of spec §7 is implemented in `Core/HealthEvaluator.swift`. New PROBLEMs
  trigger a haptic, a sound and an `app_log.txt` entry.

## Code map

```
SensorRecorder/
  App/        AppModel (services, navigation), app entry, device/version info
  Core/       TimeBase (clock anchors), CSV formatting, SessionFiles (schemas + buffered writers),
              SessionMetadata, SessionStore (folders, recovery), StreamMonitor (rates/gaps),
              HealthEvaluator (warning rules)
  Sensors/    CoreMotion / synthetic motion, CoreLocation, AVAudioRecorder, device health
  Recording/  RecordingSession (wires everything to disk), RecordingController (8 Hz dashboard),
              PreflightModel, LiveSignals (plots, roughness, ISO 2631-1 Wf MSDV estimate),
              SicknessScheduler
  Upload/     IngestBatch + accumulator, gzip (Compression + CRC32), disk UploadQueue, settings
  UI/         SwiftUI screens
```

## Tests

```bash
cd src/mobile-ios
SIM="iPhone 17 Pro"   # any iOS 17+ simulator
# optional, for the UI tests: grant permissions and give the simulator a GPS position
xcrun simctl boot "$SIM"; for p in location-always microphone motion photos; do
  xcrun simctl privacy "$SIM" grant $p com.chuds.sensorrecorder; done
xcrun simctl location "$SIM" set 46.77121,23.62363
xcodebuild -project SensorRecorder.xcodeproj -scheme SensorRecorder \
  -destination "platform=iOS Simulator,name=$SIM" test
```

- **Unit tests** cover CSV formatting, schemas, the clock math, concurrent writers, periodic flush,
  gap/rate stats, every warning rule, session.json, crash recovery, gzip/CRC, the batch payload
  shape, every upload-queue rule, the Wf filter response vs ISO values, sickness scheduling, zip
  export, and a full 3-second recording that checks every file on disk.
- **UI tests** drive the real app: setup → preflight → dashboard → every label control →
  periodic and missed sickness prompts → short tap doesn't stop → hold-to-stop → summary →
  session list, plus kill-while-recording → relaunch → RECOVERED.
- **The Simulator has no motion or barometer hardware.** Motion and barometer show "n/a" there,
  preflight can't be all green (the UI tests use the recorded *override*), GPS comes from
  `simctl location`, and audio comes from the Mac's microphone. **Real data needs the iPhone.** Unit
  tests use a test-only synthetic 100 Hz motion source to exercise the full pipeline.
- Upload batches from the UI tests go to `tools/mock_ingest_server.py` on `:8765` when it is
  running (`-upload.baseURL`).

### Tools (`tools/`)

- `quick_check.py <session_folder>`: dry-run verifier (spec §10). Stdlib only.
- `mock_ingest_server.py`: local stand-in for the Azure ingest function (same check order, strict schema,
  200 for duplicates by default). It listens on loopback by default (Simulator). For the phone, run it
  with `--host 0.0.0.0 --key <throwaway>` and set the app's URL to `http://<mac-ip>:<port>`; the phone
  asks for Local Network permission the first time.
- `test_tools.py`: tests for both tools. It includes cross-language contract tests:
  - a batch written by the app's real encoder (`tools/fixtures/ingest_batch_v1.json.gz`) must be
    accepted by the mock backend;
  - the CSV headers in `tools/fixtures/csv_headers.json` must match `quick_check.py`.
- The Swift tests compare against both fixtures and never rewrite them. After a deliberate format
  change, regenerate with `TEST_RUNNER_REGENERATE_FIXTURES=1 xcodebuild … -only-testing:SensorRecorderTests/ContractFixtureTests test`.

**Before the real drive, do the mandatory dry run (spec §10).** Record 5–10 min on the real
phone, export it, and run `python3 tools/quick_check.py <folder>`.
