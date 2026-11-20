# Sensor Recorder: iOS data-collection app

Native Swift/SwiftUI app (iOS 17+, built for an iPhone 14 Pro) that records every useful
sensor at the highest practical rate. It writes everything to local CSV files first, optionally
uploads gzipped batches to Azure, and shows a live health dashboard. The full requirements are
in [`/mobile_app.md`](../../mobile_app.md). No third-party dependencies.

## Run it on the iPhone

1. Open `src/mobile-ios/SensorRecorder.xcodeproj` in Xcode (16 or newer).
2. Target **SensorRecorder** → *Signing & Capabilities* → pick your **Personal Team**.
   If Xcode says the bundle id is taken, change `com.chuds.sensorrecorder` to something unique.
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → On** (reboot), plug it in
   and press Run. The first time, trust the developer certificate under
   *Settings → General → VPN & Device Management*.
4. Free provisioning expires after 7 days: just run it from Xcode again.

On first use the preflight asks for Motion & Fitness, Location (choose **Precise**) and Microphone.

## Using it (operator)

Sessions → **New session** → setup (pre-filled with your last values, plus a mount photo) →
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
| `location.csv`, `heading.csv` | CoreLocation; `t_up` derived from the fix's UTC timestamp |
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
- **Audio session `.playAndRecord` + mode `.measurement`** (spec: `.record`). Measurement mode
  still disables AGC/voice processing; playAndRecord is needed so prompt/alert sounds can play.
  Input is pinned to the built-in mic so the car's Bluetooth hands-free can't take over.
- **Extra files/columns:** `audio_segments.csv`, `abs_altitude.csv` (B2), `activity.csv … start_utc_ms`.
- **Upload batches are always queued** to `Documents/upload_queue/`, even with upload off,
  so a session can be uploaded later ("Upload full session") once the backend exists.
- **401/403 are retried with backoff** instead of moved to `upload_failed/`; otherwise a mistyped
  key would dump the whole queue. 408/429/5xx/network errors are retried; other 4xx go to
  `upload_failed/` (Settings → *Move failed batches back to queue*).
- **The preflight upload test is `GET {API}/api/health`**, so test data never pollutes the
  ingest table. Backend: please implement it (200 when the `x-device-key` is valid).

## Upload contract (spec §6)

`POST {API}/api/ingest` with headers `Content-Type: application/json`, `Content-Encoding: gzip`,
`x-device-key`, `x-idempotency-key: <sessionId>:<batchSeq>`. The body is exactly the spec §6
JSON (schemaVersion 1, columnar arrays, `t` relative to `t0Up`, values rounded to 6 decimals).
One request at a time, oldest first, backoff 1 → 30 s, 2xx/409 = done. The API URL and key are
entered in **Settings** at runtime (key in the Keychain); nothing secret is in the repo.

## Robustness

- Writes are buffered and flushed every 0.5 s (fsync every ~10 s) on a background queue; a crash
  loses < 1 s. Files are append-only.
- On launch, sessions without `endedAtUtc` are marked `"recovered": true`; a torn last CSV
  line is trimmed and stats are rebuilt from the files.
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
- `mock_ingest_server.py`: local stand-in for the Azure ingest API, which validates every batch.
  Point the app's Settings at `http://<mac-ip>:8080`.

**Before the real drive, do the mandatory dry run (spec §10).** Record 5–10 min on the real
phone, export it, and run `python3 tools/quick_check.py <folder>`.
