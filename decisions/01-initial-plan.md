# Mobile App — iOS Sensor Recorder (iPhone 14 Pro)

> **Audience:** a Claude Code instance (and the teammate driving it) building the iPhone data-collection app on macOS.
> This file is the complete context. Read it fully before writing code.
>
> **Status (2026-11-20):** the backend is on **Azure** (it moved to AWS and back the same day; the app contract only gains the session metadata call in §6.1). The backend architecture and the reasons behind each choice are in [02-infrastructure-plan.md](02-infrastructure-plan.md). Changes for the app: the upload target in §6 is the Azure ingest function, and §3.5 and §3.8 gained public-transport fields (audio switch, posture, handheld, line).

---

## 0. TL;DR for the builder

Build a **native iOS app (Swift + SwiftUI)** that records **every useful sensor on an iPhone 14 Pro at the highest practical rate**, **writes everything to local files first**, **streams batches to the Azure backend while recording** (the main way data reaches the cloud and the web dashboard), and shows a **live dashboard proving every stream is healthy**.

We get **ONE test drive** to collect the data. There is no second chance:

1. **Over-collect.** Extra data is filtered later. Missing data can't be recovered.
2. **Local-first.** Write to disk before doing anything else. Network failure must never lose data.
3. **Visible health.** At every moment the operator must see on screen that each stream is alive, at the expected rate, with plausible values. Anything wrong turns red immediately.
4. **Hard to break.** Stop needs a long-press. Crashes keep what was already written. The screen never auto-locks.

---

## 1. Project context

### Hackathon
- **Codelap Hackathon 2026**, "Data-Driven Infrastructure Engineering" challenge (Porsche Engineering, Cluj-Napoca).
- **Challenge:** build an end-to-end system: **Capture** (phone) → **Transmit** (securely to the cloud; we use **Azure**) → **Process** → **Store** (database) → **Visualize** (web dashboard).
- **Also required:** Infrastructure as Code plus CI/CD pipelines, and a public Git repo with regular, meaningful commits.
- **Judging:** presentation and demo, relevance and impact, technical execution, innovation and creativity.
- The guidance says *"A small, reliable stream of real data is more valuable than a complex integration that cannot be demonstrated."*

### Our idea: Road Quality + Motion Sickness, from one phone
Both features come from the **same motion signal, in different frequency bands**:

| Feature | What it answers | Frequency band | Key signals |
|---|---|---|---|
| **Road quality** | Where is the road rough? Where are the potholes, speed bumps and cobblestones? | **~1–30 Hz** plus sharp transients | Vertical acceleration, pitch/roll rate, GPS position and speed, road noise (audio) |
| **Motion sickness** | How likely is this ride to make passengers sick? Which road sections cause it? | **~0.08–0.5 Hz** (slow sway) | Lateral, longitudinal and vertical acceleration over minutes; roll/pitch; gravity orientation |

Motion sickness is computed with **ISO 2631-1 MSDV**. Frequency-weight the acceleration with filter **Wf**, then compute `MSDV = sqrt(∫ a_w(t)² dt)`. Rule of thumb: **% of people who may vomit ≈ MSDV / 3**. We validate this against **real passenger sickness ratings (MISC scale)** collected in the app during the drive.

Road quality is roughly band-passed vertical acceleration → RMS per ~10 m of road, normalized by speed → roughness score, plus spike detection → pothole events with GPS position.

**Key insight for the demo:** the roughest road is not necessarily the one that makes people sick. A smooth winding road can be worse than cobblestones. Both layers end up on one map.

### Why this data list is so large
The processing will be developed **after** the drive, from the recorded files. Every algorithm idea we come up with later (vehicle-frame alignment, speed normalization, surface classification from audio, segmenting by driving state, sensor fusion) needs its input to be in the recording already. So we record it all.

---

## 2. Tech stack and setup

- **Language/UI:** Swift 5.9+, SwiftUI. Target **iOS 17+** (iPhone 14 Pro runs iOS 17/18).
- **Frameworks:** CoreMotion, CoreLocation, AVFoundation, MapKit (live track), UIKit bits (idle timer, battery).
- **No third-party dependencies** unless unavoidable. Less to go wrong.
- **Signing:** free Apple ID ("Personal Team") is enough to run on your own iPhone. The provisioning lasts 7 days, so re-run from Xcode if it expires. On the iPhone, enable **Settings → Privacy & Security → Developer Mode**.
- **Code location in repo:** `src/mobile-ios/` (Xcode project inside).

### Info.plist / capabilities
| Key | Value / reason |
|---|---|
| `NSMotionUsageDescription` | "Records vehicle motion to measure road quality and ride comfort." |
| `NSLocationWhenInUseUsageDescription` | "Maps road quality along the route." |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Same, so recording continues if the app goes to the background |
| `NSMicrophoneUsageDescription` | "Records road noise to classify road surfaces." |
| `NSCameraUsageDescription` | Only if you implement the mount photo (P1) |
| `UIBackgroundModes` | `location`, `audio`. These keep the app and sensors alive if it gets backgrounded |
| `UIFileSharingEnabled` = YES, `LSSupportsOpeningDocumentsInPlace` = YES | Session files become visible in the **Files app** and in Finder over USB. This is the zero-code export fallback |

---

## 3. What to record (complete list)

Priority:
- **P0** = must have; the drive is pointless without it.
- **P1** = should have; very likely needed.
- **P2** = nice to have; implement if time allows and it doesn't destabilize P0.

**Units:** store **native iOS units** exactly as the API delivers them, with no conversion in the app. Units are documented per column below. The backend converts (1 g = 9.80665 m/s²).

**Request 100 Hz** for all motion streams (`updateInterval = 0.01`) and **measure and display the actual rate**. iOS caps CoreMotion at about 100 Hz on iPhone.

### 3.1 Motion (CoreMotion), the core data

| # | Stream | API | Rate | Fields (unit) | Why | Prio |
|---|---|---|---|---|---|---|
| M1 | **Device motion (fused)** | `CMMotionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to:)` | 100 Hz | `userAcceleration.x/y/z` (g), `gravity.x/y/z` (g), `rotationRate.x/y/z` (rad/s), `attitude.quaternion.w/x/y/z`, `attitude.roll/pitch/yaw` (rad) | Gravity vector = "which way is down", used to rotate into the vehicle frame. Attitude gives roll/pitch for sickness. userAcceleration is handy for road spikes | **P0** |
| M2 | **Raw accelerometer** | `startAccelerometerUpdates` | 100 Hz | `x/y/z` (g, gravity included) | **Unfused** signal. The fused userAcceleration can filter out the very slow 0.1–0.5 Hz motion that MSDV needs, so the backend must have raw data | **P0** |
| M3 | **Raw gyroscope** | `startGyroUpdates` | 100 Hz | `x/y/z` (rad/s, includes bias) | Unfused rotation; pitch spikes help confirm potholes (front then rear axle) | **P0** |
| M4 | Raw magnetometer | `startMagnetometerUpdates` | 50 Hz | `x/y/z` (µT) | Car metal distorts it, but it's cheap and may help heading or detect electrical noise | P2 |

Notes:
- Use **one** `CMMotionManager` instance for the whole app (Apple requirement).
- Deliver updates to a dedicated `OperationQueue` (not main). Hand samples to the file writer and to a light ring buffer for the UI.
- Use reference frame `.xArbitraryZVertical`, **not** a magnetometer-based one. The car's metal makes magnetic yaw correction unreliable, and we only need gravity, roll and pitch.
- Every `CMLogItem` has `.timestamp` = **seconds since device boot**, a monotonic clock. Record it as-is (see §5, Time).

### 3.2 Location (CoreLocation)

| # | Stream | Settings | Fields (unit) | Why | Prio |
|---|---|---|---|---|---|
| L1 | **GPS fixes** | `desiredAccuracy = kCLLocationAccuracyBestForNavigation`, `distanceFilter = kCLDistanceFilterNone`, `activityType = .automotiveNavigation`, `pausesLocationUpdatesAutomatically = false`, `allowsBackgroundLocationUpdates = true`, `showsBackgroundLocationIndicator = true` | `timestamp` (Date, UTC), `latitude`, `longitude` (deg), `altitude` (m), `ellipsoidalAltitude` (m), `horizontalAccuracy`, `verticalAccuracy` (m), `speed` (m/s), `speedAccuracy` (m/s), `course` (deg), `courseAccuracy` (deg), `sourceInformation?.isSimulatedBySoftware` | Places every measurement on the map. **Speed is essential**: roughness must be normalized by speed. Course helps find the vehicle's forward axis. Accuracy lets us discard bad fixes | **P0** |
| L2 | Heading (compass) | `startUpdatingHeading`, `headingFilter = kCLHeadingFilterNone` | `magneticHeading`, `trueHeading`, `headingAccuracy` (deg), raw `x/y/z` | Unreliable in a car, cheap to record | P2 |

- Request **precise** location (`accuracyAuthorization == .fullAccuracy`). If the user granted only approximate location, the preflight check shows red.
- GPS on iPhone delivers about 1 Hz. That's expected; don't try to "fix" it.

### 3.3 Barometer / altitude (CoreMotion `CMAltimeter`)

| # | Stream | Fields (unit) | Why | Prio |
|---|---|---|---|---|
| B1 | Relative altitude | `relativeAltitude` (m), `pressure` (kPa) | Hills and slopes (vertical motion context); a smoother altitude than GPS | **P1** |
| B2 | Absolute altitude | `startAbsoluteAltitudeUpdates`: `altitude`, `accuracy`, `precision` (m) | Same, absolute | P2 |

### 3.4 Activity (CoreMotion `CMMotionActivityManager`)

| # | Stream | Fields | Why | Prio |
|---|---|---|---|---|
| A1 | Motion activity | `stationary`, `walking`, `running`, `automotive`, `cycling`, `unknown` (bool), `confidence` (0/1/2), `startDate` | Free automatic segmentation into "driving" and "stopped" (stopped = engine-idle baseline) | **P1** |

### 3.5 Audio (AVFoundation)

| # | Stream | Settings | Why | Prio |
|---|---|---|---|---|
| S1 | **Audio level meter** | From the recorder (`isMeteringEnabled`) or an `AVAudioEngine` input tap: compute **RMS dBFS and peak dBFS at 10 Hz** | Road/tyre noise changes strongly with surface (cobblestones, asphalt, gravel). Cheap and anonymous | **P1** |
| S2 | **Audio recording** | `AVAudioSession` category `.record`, **mode `.measurement`** (turns off auto gain and voice processing, which matters for measurement), AAC, 48 kHz (or 44.1), mono, ~64 kbps, `.m4a`, saved locally only | Lets us classify road surface from sound later (frequency analysis); also an audible "sync tap" (§5) | **P1** |

- ⚠️ This records conversations in the car. **Tell everyone in the car.** Never upload the raw audio live; it stays on the phone and goes into the session folder.
- ⚠️ **Turn audio recording off on public transport** (other passengers' conversations, GDPR). Session setup has an `audioEnabled` switch that defaults to off when the vehicle type is `bus` or `tram`. The audio *level* meter (S1, numbers only) may stay on.
- Store the uptime at which recording actually started (see §5).

### 3.6 Device health (polled every 5 s)

| # | Field | Why | Prio |
|---|---|---|---|
| D1 | `UIDevice.batteryLevel`, `batteryState` | Battery drain; charging state | **P0** |
| D2 | `ProcessInfo.thermalState` (nominal/fair/serious/critical) | A hot phone **throttles sensors and CPU**, which would explain bad data | **P0** |
| D3 | `ProcessInfo.isLowPowerModeEnabled` | Low Power Mode can reduce rates; must be off | **P0** |
| D4 | Free disk space (bytes) | Never run out of disk mid-drive | **P0** |
| D5 | Network reachability (`NWPathMonitor`: satisfied/unsatisfied, cellular/wifi) | Explains upload gaps | P1 |

### 3.7 Human labels (manual input during the drive), the ground truth

The operator is **a passenger, never the driver.**

| # | Label | UI | Why | Prio |
|---|---|---|---|---|
| H1 | **Sickness rating (MISC 0–10)** | Prompted **every 2 minutes** with a haptic and a short sound. Big 0–10 grid with short descriptions. Auto-dismisses after 30 s with no answer (logged as `missed`). Can also be entered any time | Ground truth to validate MSDV predictions. **Without it the sickness feature is unvalidated** | **P0** |
| H2 | **Bump / pothole** | One big button, tapped the moment the bump is felt | Ground truth for pothole detection | **P0** |
| H3 | Speed bump | Button | Different signature from a pothole | **P0** |
| H4 | Surface segment | Toggle buttons with start/end: `cobblestones`, `rough asphalt`, `smooth asphalt`, `gravel`, `tram rails` | Labeled training data for roughness and surface classification | **P0** |
| H5 | Driving segment | Toggle start/end: `winding road`, `roundabout`, `stop-and-go`, `highway`, `idle (stationary)` | Context for sickness analysis | P1 |
| H6 | **Phone moved / touched** | Button | Marks data as **invalid** in that window. Critical | **P0** |
| H7 | **Sync tap** | Button + instructions (§5) | Alignment of audio and motion | P1 |
| H8 | Free-text note | Small text field | Anything unexpected | P1 |

**MISC (Misery Scale) labels for the grid:**
`0` no problems · `1` slight discomfort, no specific symptoms · `2` dizziness, warmth, headache, stomach awareness, sweating: vague · `3` same: some · `4` same: medium · `5` same: severe · `6` nausea: some · `7` nausea: medium · `8` nausea: severe · `9` retching · `10` vomiting

Note: looking at a phone screen itself increases motion sickness. The person rating should only glance at the phone when prompted. Record **who is rating and their seat** in the session metadata.

### 3.8 Session metadata (entered before recording, in `session.json`)

```json
{
  "sessionId": "UUID",
  "appVersion": "1.0.0 (git sha if available)",
  "device": { "model": "iPhone15,2", "name": "iPhone 14 Pro", "iosVersion": "18.1" },
  "timezone": "Europe/Bucharest",
  "startedAtUtc": "2026-11-21T09:12:03.512Z",
  "startUptimeSec": 123456.789012,
  "endedAtUtc": null,
  "vehicle": { "type": "car|bus|tram|bike|boat", "makeModel": "string", "line": "bus/tram line number, or null", "notes": "" },
  "mount": {
    "location": "e.g. taped flat on center console",
    "phoneOrientation": "e.g. screen up, top of phone pointing to vehicle front",
    "rigid": true,
    "handheld": false,
    "seatOverAxle": false,
    "photoFile": "mount.jpg"
  },
  "people": { "operatorSeat": "front passenger", "raterSeat": "rear left", "raterPosture": "seated|standing", "passengerCount": 3 },
  "audioEnabled": true,
  "conditions": { "weather": "dry", "notes": "" },
  "requestedRatesHz": { "deviceMotion": 100, "accel": 100, "gyro": 100, "mag": 50, "audioLevel": 10 },
  "recovered": false,
  "stats": { "filled at end: sample counts and measured mean rate per stream, drop count, file sizes" : "" }
}
```

**Mount photo (P1):** before recording, the app asks for one photo of the phone in its mount and saves it as `mount.jpg`. Phone orientation relative to the vehicle is essential for the axis transformation, and a photo removes all ambiguity.

---

## 4. Storage format (local-first)

One folder per session in the app's **Documents** directory, so it shows in the Files app:

```
Documents/sessions/2026-11-21T09-12-03Z_<shortId>/
├── session.json          # metadata (§3.8), rewritten at start and end
├── clock.csv             # time sync anchors (§5)
├── device_motion.csv     # M1
├── accel_raw.csv         # M2
├── gyro_raw.csv          # M3
├── mag_raw.csv           # M4 (P2)
├── location.csv          # L1
├── heading.csv           # L2 (P2)
├── altimeter.csv         # B1 (+B2 columns or abs_altitude.csv)
├── activity.csv          # A1
├── audio_000.m4a, …      # S2, 5-minute segments (crash-safe; see the app README)
├── audio_segments.csv    # start/stop/interrupted/reset per audio file; blocked_background = gap until the app is opened
├── abs_altitude.csv      # B2
├── audio_level.csv       # S1
├── device.csv            # D1–D5
├── labels.csv            # H1–H8
├── app_log.txt           # warnings, errors, permission states, rate drops, upload failures
└── mount.jpg             # P1
```

### CSV schemas (header row required, comma-separated, `.` decimal, no thousands separators)

Common leading columns on every sensor CSV:
- `t_up`: sensor timestamp, **seconds since boot**, 6 decimals (CoreMotion `timestamp`, or converted for Date-based APIs)
- `t_utc_ms`: Unix epoch milliseconds (UTC), computed from the clock anchor (§5)

| File | Columns after `t_up,t_utc_ms` |
|---|---|
| `device_motion.csv` | `ua_x,ua_y,ua_z,g_x,g_y,g_z,rr_x,rr_y,rr_z,q_w,q_x,q_y,q_z,roll,pitch,yaw` |
| `accel_raw.csv` | `x,y,z` |
| `gyro_raw.csv` | `x,y,z` |
| `mag_raw.csv` | `x,y,z` |
| `location.csv` | `lat,lon,alt,ell_alt,h_acc,v_acc,speed,speed_acc,course,course_acc,is_simulated` (for location, `t_utc_ms` comes from `CLLocation.timestamp` and `t_up` is derived) |
| `heading.csv` | `mag_heading,true_heading,heading_acc,x,y,z` |
| `altimeter.csv` | `rel_alt_m,pressure_kpa` |
| `activity.csv` | `stationary,walking,running,automotive,cycling,unknown,confidence` |
| `audio_level.csv` | `avg_dbfs,peak_dbfs` |
| `device.csv` | `battery_level,battery_state,thermal_state,low_power,free_disk_bytes,net_status,net_type` |
| `labels.csv` | `type,value,note` (e.g. `sickness,4,` / `pothole,,` / `surface_start,cobblestones,` / `surface_end,cobblestones,` / `phone_moved,,` / `sickness_missed,,`) |
| `clock.csv` | `t_up,t_utc_ms,source` (no extra columns) |

Use the same numeric precision everywhere: 6 decimals for sensor values, 8 decimals for lat/lon.

### Writer requirements
- One **serial background queue** per file (or one shared writer queue). Never write on the main thread.
- Buffer in memory and **flush to disk at least every 1 second**. A crash then loses at most 1 s.
- Append-only. Never rewrite sensor files.
- On app launch, if a session folder lacks `endedAtUtc`, mark it `"recovered": true`, keep it, and show it in the session list.
- **Expected size:** about 100–150 MB per hour total (CSV plus audio). An iPhone 14 Pro has plenty of space; still show free space.

---

## 5. Time: get this right, it can't be fixed later

- CoreMotion timestamps are **seconds since boot** (same clock as `ProcessInfo.processInfo.systemUptime`).
- CoreLocation gives a UTC `Date`.
- **Anchor:** at session start and then **every 10 s**, write `clock.csv` rows with `systemUptime` and `Date().timeIntervalSince1970*1000` read back-to-back. The conversion is `utc_ms = anchor_utc_ms + (t_up - anchor_up) * 1000`, using the nearest anchor.
- Keep the screen awake (`UIApplication.shared.isIdleTimerDisabled = true`) so the device never sleeps during recording.
- **Sync tap (P1):** right after Start, and again before Stop, the operator presses "Sync tap" and then **knocks firmly on the phone/mount 3 times**. That leaves a sharp spike in the accelerometer **and** a click in the audio, so we can align audio and motion to the millisecond later.
- Record the uptime when `AVAudioRecorder.record()` returns, in `clock.csv` with `source=audio_start`.

---

## 6. Live upload to Azure (the main path to the cloud; must never block recording)

The API base URL points at the Azure ingest function app (see [02-infrastructure-plan.md](02-infrastructure-plan.md)); the function serves `/api/ingest`. The backend answers `200` for both new and repeated batches; the app should still treat `409` as success, as below. Live upload is how data reaches the cloud and the web dashboard; uploading the session folder from a laptop is only a fallback for trips that never got a connection.

The app must still work **fully offline**: recording never depends on the network. Without a connection, batches wait in the disk queue and are sent, oldest first, when the network returns, so a dead zone delays data but doesn't lose it.

- **Settings screen:** `API base URL` and `Device key` (stored in UserDefaults/Keychain; **never hard-coded in the repo**). Empty URL = upload disabled. Show "UPLOAD OFF (local only)" in neutral grey, not red.
- **Batching:** every **2 s**, build one batch from the samples of that window (in-memory copy; disk files stay the source of truth).
- **Endpoint contract:**

```
POST {API_BASE}/api/ingest
Content-Type: application/json
Content-Encoding: gzip
x-device-key: <device key>
```

```json
{
  "schemaVersion": 1,
  "sessionId": "UUID",
  "deviceId": "stable per-install UUID (identifierForVendor)",
  "batchSeq": 142,
  "t0Utc": "2026-11-21T09:15:32.120Z",
  "t0Up": 123532.408211,
  "units": { "accel": "g", "gyro": "rad/s", "speed": "m/s", "pressure": "kPa" },
  "deviceMotion": { "t": [0.0, 0.01, ...], "ua_x": [...], "ua_y": [...], "ua_z": [...],
                    "g_x": [...], "g_y": [...], "g_z": [...],
                    "rr_x": [...], "rr_y": [...], "rr_z": [...],
                    "q_w": [...], "q_x": [...], "q_y": [...], "q_z": [...] },
  "accelRaw": { "t": [...], "x": [...], "y": [...], "z": [...] },
  "gyroRaw":  { "t": [...], "x": [...], "y": [...], "z": [...] },
  "location": [ { "tUtcMs": 1763716532120, "lat": 46.77121, "lon": 23.62363, "alt": 352.1,
                  "hAcc": 4.7, "speed": 8.4, "speedAcc": 0.5, "course": 92.0 } ],
  "altimeter": { "t": [...], "relAltM": [...], "pressureKpa": [...] },
  "audioLevel": { "t": [...], "avgDbfs": [...], "peakDbfs": [...] },
  "labels": [ { "t": 1.24, "type": "pothole", "value": null, "note": null } ],
  "device": { "battery": 0.82, "thermal": "nominal", "lowPower": false }
}
```

  - `t` arrays are **seconds relative to `t0Up`** (columnar to keep payloads small).
  - Size: about 30 KB raw / ~10 KB gzipped per batch, roughly 20 MB/hour of mobile data.
- **Queue on disk** (`Documents/upload_queue/`): write each batch as a `.json.gz` file, upload oldest first, **1 request at a time**, exponential backoff (1 s → 30 s max). Delete on HTTP 2xx. **Treat 409 (duplicate) as success.** Other 4xx: log, move to `upload_failed/`, continue.
- Idempotency key = `sessionId + batchSeq`.
- After the drive, a **"Upload full session"** button can send the queued remainder. The raw audio is **not** uploaded.

### 6.1 Session metadata (new: the backend needs it for the live path)

The backend learns a trip's context (vehicle, mount, seat, posture) and when it ended from `session.json`. Without it, a live trip shows on the dashboard but can't be compared with other trips.

```
PUT {API_BASE}/api/ingest/sessions/{sessionId}
Content-Type: application/json
Content-Encoding: gzip
x-device-key: <device key>
```

- Body: the current `session.json` (§3.8). In the Stop copy, add `"batchCount"`: the number of batches created for the session, so the backend knows when every batch has arrived.
- Send it **at Start** (right after `session.json` is first written) and **at Stop** (after it is rewritten with `endedAtUtc` and `stats`).
- Put it in the **same disk queue** as the batches, so it is sent in order: the Start copy before batch 0, the Stop copy after the last batch. The queue file name needs a marker that tells it apart from a batch.
- Same rules as batches: 2xx and 409 = done, same backoff. The backend answers `200` for a repeat.
- Until this exists, the backend creates the trip from its first batch with unknown context and closes it after 15 minutes without batches.

### 6.2 What the app sends beyond the example above (implementation, app v1.0)

Everything here is **additive**: the §6 keys keep their names, types and units, so the backend must accept extra keys (no pydantic `extra="forbid"`, no fixed `units` literal). The app's `tools/mock_ingest_server.py` validates all of it and is tested against payloads produced by the app's own encoder (`src/mobile-ios/tools/fixtures/`).

- **Full dataset in every batch** (02 D32, only raw audio stays on the phone): `deviceMotion.roll/pitch/yaw`; `magRaw {t,x,y,z}` (µT, 50 Hz); `heading [{tUtcMs, magHeading, trueHeading, headingAcc, x, y, z}]`; `absAltitude {t, altitudeM, accuracyM, precisionM}`; `activity [{t, stationary, walking, running, automotive, cycling, unknown, confidence, startUtcMs}]`; `location[].ellAlt, vAcc, courseAcc, isSimulated`; `device.batteryState, freeDiskBytes, netStatus, netType`.
- **Hackathon payload rule** ("device ID, event type, value, unit, UTC timestamp"): `eventType: "sensor_batch"`, `source: "live"`, `t0UtcMs` (sample UTC = `t0UtcMs + t[i]·1000`), `fieldUnits` (the unit of every field). Accelerations stay in **g** as the iPhone delivers them (`1 g = 9.80665 m/s²`); invalid speed/course/accuracies are **−1** as in iOS.
- **Headers:** `x-idempotency-key: <sessionId>:<batchSeq>` for batches, `<sessionId>:meta-start|meta-stop` for §6.1.
- **§6.1 body:** `session.json` plus `source: "live"` (the replay tool rewrites it) and, in the Stop copy, `batchCount`. `people.raterName` is removed from the cloud copy (personal data stays on the phone).
- **Queue:** files `<createdMs>_<sessionId>_<batchSeq>.json.gz` and `<createdMs>_<sessionId>_meta-start|stop.json.gz`; lexical order is send order. `createdMs` is strictly increasing per queue (a wall clock that steps back can't sort the Stop copy before the last batch), and files are never re-ordered. `batchSeq` counts only batches actually queued: windows recorded while the URL was empty use no number, and a batch whose enqueue failed (full disk) keeps no number and is retried at the next tick (up to 30 s of windows), so `batchCount` is exact with no holes. A `.json.gz` file whose name the app didn't write (e.g. a Files-app copy) or that can't be read is moved to `upload_failed/`, never left blocking the queue. After the Stop copy is queued the app asks iOS for background time until the queue is empty. Recovered (crashed) sessions send no Stop copy; the 15-minute close applies.
- **Statuses:** 2xx/409 done; 401/403/404 (batches) and 408/429/5xx/network retried in place with backoff 1→30 s, however long it takes (the ingest function answers 503 only for its own outages, never for a bad payload, so an outage never parks or re-orders anything); for session metadata 404/405 means "no PUT route yet" (or a redeploy in progress): it is retried 8 times (about 2 min) and then set aside in `upload_failed/`, so it never blocks the batches for good; other 4xx go to `upload_failed/`; redirects are never followed. A file that was sent but can't be deleted is not sent again. Plain `http://` is accepted only for local test servers, and a pasted base URL ending in `/api/ingest` is reduced to its base.
- **Size:** a 2 s batch is about 45 KB of JSON (about 16 KB gzipped); the app logs a warning above 180 KB (the function's limit is 200 KB decompressed).

---

## 7. App screens and the live health dashboard

### Screen 1: Sessions
- List of past sessions (date, duration, size, recovered flag) → tap → detail plus **Export** (share sheet / AirDrop the folder, or open in Files).
- Button **New session**.

### Screen 2: Session setup
- Form for the metadata in §3.8 (vehicle, mount location, phone orientation, seats, weather). Sensible defaults so it takes 30 s.
- **Mount photo** (P1).

### Screen 3: Preflight checklist (blocks Start until required items pass; with an "override" for emergencies)
| Check | Pass condition |
|---|---|
| Motion permission | authorized |
| Location permission | authorized + **full accuracy** |
| Microphone permission | authorized |
| Device motion / accel / gyro available | `is…Available == true` |
| Barometer available | `CMAltimeter.isRelativeAltitudeAvailable()` |
| **GPS fix** | `horizontalAccuracy ≤ 10 m` (live value shown) |
| **Measured motion rate** | ≥ 90 Hz for each motion stream over a 3 s test |
| **Mount stillness test** | 5 s with vehicle stopped: accel std-dev below 0.03 g (an idling engine exceeds 0.01 g). Also stores the gravity vector |
| Low Power Mode | **off** |
| Battery | ≥ 50 % or charging |
| Thermal | nominal or fair |
| Free disk | ≥ 2 GB |
| Upload (if configured) | test POST succeeds (warning only, never blocking) |

### Screen 4: Recording dashboard (the important one)

One glance must answer: **is everything recording correctly right now?**

```
┌──────────────────────────────────────────┐
│ ● REC  00:23:41      session 7f3a        │
│ ██████ ALL STREAMS OK ██████  (green)    │  ← big banner: green OK / amber WARN / red PROBLEM + reason
├──────────────────────────────────────────┤
│ STREAM        RATE     SAMPLES   AGE  ●  │
│ DeviceMotion  99.8 Hz  142,031   0.0s ●  │
│ Accel raw     99.9 Hz  142,040   0.0s ●  │
│ Gyro raw      99.9 Hz  142,038   0.0s ●  │
│ Magnetometer  50.0 Hz   71,010   0.0s ●  │
│ GPS            1.0 Hz    1,421   0.4s ●  │  hAcc 4.7 m · 38 km/h
│ Barometer      ~1 Hz     1,402   0.6s ●  │
│ Activity       auto      automotive(hi)  │
│ Audio rec      ON 48k    12.4 MB      ●  │  level −31 dBFS ▮▮▮▮▯▯
│ Disk written   58.2 MB   free 41.3 GB ●  │
│ Upload         queue 0   last OK 1.8s ●  │  (or "OFF – local only")
│ Battery 78% ⚡ · Thermal nominal · LPM off│
├──────────────────────────────────────────┤
│ [live plot] vertical accel, last 10 s    │  ← road band: you SEE bumps
│ [live plot] lateral accel (low-pass), 60s│  ← sickness band: you SEE sway in curves
│ [mini map] track so far, colored by speed│
│ Roughness now: 0.42  ·  MSDV so far: 3.1 │  (simple on-device estimates, optional)
├──────────────────────────────────────────┤
│ [POTHOLE] [SPEED BUMP] [PHONE MOVED]     │  ← big buttons, haptic feedback on tap
│ Surface: [cobble][rough][smooth][gravel] │  ← toggles, highlighted while active
│ Segment: [winding][roundabout][stop&go]  │
│ [SICKNESS 0–10]  [SYNC TAP]  [NOTE]      │
│                    (hold 2 s to STOP) ■  │
└──────────────────────────────────────────┘
```

- Every row has a **status dot**: green / amber / red.
- **Last label** shows briefly as a toast ("Pothole logged 09:23:41") so the operator knows the tap registered.
- Each sickness prompt shows a countdown; answering gives haptic confirmation.
- Use high contrast, big text, and support for bright sunlight. Dark mode is fine.
- UI refresh at **5–10 Hz** (not per sample). Plots draw from ring buffers, decimated.

### Warning rules (amber = WARN, red = PROBLEM)

| Condition | Level |
|---|---|
| Any motion stream rate < 90 Hz (over a 2 s window) | WARN |
| Any motion stream rate < 50 Hz, or no sample for > 0.5 s | **PROBLEM** |
| GPS no fix for > 5 s | WARN; > 15 s **PROBLEM** |
| GPS `horizontalAccuracy` > 20 m | WARN |
| Audio recorder not recording | **PROBLEM** |
| Disk write error / file flush fails | **PROBLEM** |
| Free disk < 1 GB | WARN; < 300 MB **PROBLEM** |
| Thermal `serious` | WARN; `critical` **PROBLEM** |
| Low Power Mode turned on | **PROBLEM** |
| Battery < 20 % and not charging | WARN |
| App went to background | WARN (recording continues via background modes; log it) |
| Upload queue > 30 batches or last success > 60 s | WARN (never PROBLEM: data is safe on disk) |
| Sickness prompt missed | info (logged) |

On PROBLEM: red banner with the reason, a strong haptic, and a sound, plus an `app_log.txt` entry with a timestamp.

### Screen 5: Session summary (after Stop)
- Duration, per-stream sample count, **mean measured rate**, longest gap per stream, labels count, sickness ratings count, file sizes, upload status.
- Any stream with gaps > 1 s is listed in red. This is the immediate answer to "did we get good data?"
- **Export** button.

---

## 8. Robustness checklist

- [ ] `isIdleTimerDisabled = true` while recording; restore after.
- [ ] Stop requires **2 s long-press**; no accidental stop. No "pause" at all; use segment labels instead.
- [ ] Background modes `location` + `audio` enabled, so if the app goes to the background, recording continues.
- [ ] Handle audio interruptions (phone call, Siri): log it, try to resume, show WARN.
- [ ] All sensor callbacks on background queues; the main thread only renders.
- [ ] Files flushed ≥ 1×/s; unfinished sessions recovered on next launch.
- [ ] Nothing secret committed: API key entered at runtime.
- [ ] Session folder visible in the **Files app** (UIFileSharingEnabled), so even with zero export code we can get the data off via USB/Finder or AirDrop.
- [ ] The app works with **no network at all**.

---

## 9. Drive protocol (for the operator, also shown on an in-app help screen)

**Before driving**
1. Phone charged and **plugged into the car charger**. Low Power Mode off, Do Not Disturb on.
2. **Mount the phone rigidly.** Best: taped or clamped flat on the center console, screen up, top of phone toward the vehicle front. Avoid wobbly air-vent mounts, which add their own vibration. **Never move it during the drive**; if it moves, press PHONE MOVED.
3. Fill in the session setup and take the mount photo.
4. Run the preflight; everything must be green.
5. Start recording, then press **SYNC TAP** and knock firmly 3 times.
6. **Stationary baselines:** 30 s engine off, then 30 s engine idling (label `idle`).

**During the drive (try to cover all of these, and label them)**
- Smooth asphalt, straight, constant speed (baseline)
- **Cobblestones**, rough or patched asphalt, potholes, **speed bumps**, tram rails
- **Winding road / roundabouts / curves** (lateral sway, the main sickness driver)
- **Stop-and-go** traffic (longitudinal sway)
- Some faster road segment if possible
- If possible, drive one rough segment **twice at different speeds** (e.g. 20 and 40 km/h). This lets us prove the speed normalization works.
- Sickness ratings every 2 min from a rear passenger.

**After the drive**
1. 30 s stationary, engine idling, then SYNC TAP + 3 knocks, then **hold to Stop**.
2. Check the summary screen for red rows.
3. **Immediately export** the session folder (AirDrop to a laptop, plus Files → iCloud Drive or another copy). Keep **two copies** before doing anything else.

---

## 10. Before the real drive: mandatory dry run

Do a **5–10 minute test** (walk or drive around the block) and then verify on a laptop:

```python
# quick_check.py: run on the exported session folder
import pandas as pd, sys, pathlib
d = pathlib.Path(sys.argv[1])
for f in ["device_motion","accel_raw","gyro_raw","location","altimeter","audio_level","labels"]:
    p = d / f"{f}.csv"
    if not p.exists(): print(f"MISSING {f}"); continue
    df = pd.read_csv(p)
    if "t_up" in df and len(df) > 1:
        dt = df["t_up"].diff().dropna()
        print(f"{f:15s} rows={len(df):8d} rate={1/dt.median():6.1f}Hz max_gap={dt.max():.3f}s")
    else:
        print(f"{f:15s} rows={len(df)}")
print("audio", sum(f.stat().st_size for f in d.glob("audio_*.m4a")) or "MISSING")
```

The full verifier is `src/mobile-ios/tools/quick_check.py` (stdlib only): headers, rates, gaps, clock alignment, labels, audio segments, coverage and session.json.

Pass criteria: motion streams ~100 Hz with max gap < 0.1 s; GPS ~1 Hz with sane coordinates; labels present with the right timestamps; audio file plays; `t_utc_ms` values are the correct real time.

---

## 11. Build order (if time is short, stop after any step and you still have a usable app)

1. **Recorder core:** CoreMotion M1–M3 + GPS L1 → CSV writer + clock anchors + idle-timer off. *(Minimum viable: this alone is enough for the drive.)*
2. **Live dashboard:** stream table with rates, sample counts, ages, status dots, and the banner.
3. **Labels:** pothole / speed bump / phone moved / surface toggles / sickness prompt.
4. Preflight checklist + session setup + summary + export.
5. Audio recording + level meter, barometer, activity, device health.
6. Live plots + mini map.
7. Live upload queue to Azure.
8. P2 extras (magnetometer, heading, absolute altitude, on-device roughness/MSDV estimates).

---

## 12. Out of scope for the app
- Any real signal processing (filtering, MSDV, roughness, pothole detection). That happens in the cloud from the raw data. On-device estimates are only for the live display.
- User accounts or login. A per-install device ID and a device key are enough.
- Android. Single device: iPhone 14 Pro.
