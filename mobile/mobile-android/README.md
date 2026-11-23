# Bumpy: Android data-collection app

Kotlin/Compose port of the [iPhone recorder](../mobile-ios/README.md) (D58): the same screens, the same
session folder, the same upload queue and contract. What the app does, what it writes and why is described
in the iOS README; this file lists only what is different on Android.

Android 10 (API 29) or newer, with an accelerometer, a gyroscope, the game rotation vector and GPS. Magnetometer and
barometer are used when present.

## Run it on a phone

1. Open `mobile/mobile-android` in Android Studio, or build from a terminal (JDK 17+, the Android SDK in
   `local.properties`): `./gradlew :app:assembleRelease`.
2. Turn on USB debugging on the phone and run `adb install app/build/outputs/apk/release/app-release.apk`.
3. Open Bumpy and allow **Precise** location **while using the app**.
4. Menu → Settings: server address and device key. Find the Device ID as on iOS (`deviceId` in any trip's
   `session.json`), then create the key with `infra/scripts/add-device-key.ps1`.
5. Before a drive: Battery Saver off. On phones whose maker kills background apps (Xiaomi, Huawei, Samsung…),
   set Bumpy's battery use to *Unrestricted* and keep it on screen.

The release build is signed with the building PC's debug key. A build from another PC can't update it, and
uninstalling deletes the trips unless **Keep app data** is ticked: verify every trip in the cloud first. The
Device ID depends on the signing key too, so a build from another PC also needs its own device key.

`./gradlew :app:assembleRelease -PdashboardUrl=https://…` turns on the web app links. Debug builds also take
`adb shell am start -n com.chuds.sensorrecorder/.app.MainActivity --es upload.baseURL http://10.0.2.2:8765 --es dashboard.baseURL https://…`.

## Automatic trips (D59)

Menu → Settings → **Start trips automatically** (off by default). It needs location **Allow all the time** (the
Location row asks once, then opens the system settings), **Physical activity** (the step detector) and
notifications; without them the switch stays off and says what is missing. **Vehicle** (car, bus, tram) applies to
every trip, manual ones too; **Phone is firmly mounted** is an automatic trip's `mount.rigid`.

- **Watching:** the recording service runs as a location service with a silent "Auto-start on" notification,
  network/passive location every ~20 s and the step detector. No step for a minute while moving makes the phone a
  candidate: GPS then runs at 1 Hz and the Start screen's checks run silently (no stillness test, no upload probe).
  30 s above 20 km/h within 90 s starts the trip; 10 min below 1.5 m/s, or 60 s of walking below 2 m/s, stops it.
  Without Play Services there is no activity recognition: a bike ride above 20 km/h starts a trip too (Cancel it).
- **Cancel** in the "Trip started automatically" notification needs the phone unlocked (Android 11 and older:
  it opens Bumpy to confirm). Within the first 2 minutes nothing has been uploaded and the trip is deleted; later
  it stops, is kept and is marked `autoStart.cancelledAtUtc`.
- **Not recorded:** the drive before the phone notices it (about the first minute) and the warm-up.
- **Battery:** watching costs little (no GPS, no wake lock); a candidate runs GPS and keeps the CPU awake until it
  either starts a trip or stops moving for 3 minutes.
- **Limits:** Android lets an app start a location service only from the foreground, so watching starts when
  Bumpy is opened. After a reboot or an app update Bumpy tries to re-arm by itself; on Android 14+ and on phones
  whose maker blocks boot starts this can be refused: if "Auto-start on" isn't in the notifications, open Bumpy
  once. The same after Android killed the app (battery setting not *Unrestricted*) or after a force stop: nothing
  starts until Bumpy is opened again.

## Getting trips off the phone

`Android/data/com.chuds.sensorrecorder/files/sessions/` over USB or with `adb pull`, or the **Bumpy** entry in
the phone's Files app (read-only). `tools/upload`, `tools/replay` and `quick_check.py` read the folders as they are.

## How Android's data becomes the iOS data

Only `sensors/` knows Android. Everything after it carries iOS units, axes and signs, because the backend was
built on them (`UA_SIGN` in `services/processor/roadride/dsp.py`).

| Data | From | Conversion |
|---|---|---|
| `accel_raw` | `TYPE_ACCELEROMETER` | negated, ÷ 9.80665 (flat, screen up, at rest: z = −1) |
| `device_motion` gravity, attitude | `TYPE_GAME_ROTATION_VECTOR` | the rotation's down vector, so always 1 g; angles as CoreMotion's |
| `device_motion` user acceleration | raw accelerometer − gravity | as CoreMotion defines it (+1 g on z in free fall) |
| `device_motion` rotation rate | `TYPE_GYROSCOPE` | unchanged |
| `gyro_raw`, `mag_raw` | the uncalibrated sensors | unchanged (CoreMotion's raw streams include the bias too) |
| `altimeter` | `TYPE_PRESSURE` | hPa → kPa, once a second, relative to the first sample |
| `location` | GPS provider only | `alt` = mean sea level (Android 14, or the chip's NMEA geoid height; empty until known), `ell_alt` = ellipsoid; missing speed/course/accuracy = −1 |
| `heading` | rotation vector + magnetometer | at most 10 Hz |
| `t_up` | `elapsedRealtimeNanos` | a sensor on another clock is shifted once, at its first sample, and logged |

`deviceMotion` has one sample per accelerometer sample, with rotation and gyro interpolated to its time, never
across a gap over 0.1 s. Android may run a sensor faster than the 100 Hz asked for (up to 220 Hz): above
150 Hz, `deviceMotion` averages neighbouring accelerometer samples; the raw files keep every sample.

## Different from iOS, and why

- **`activity.csv` and `abs_altitude.csv` are header-only** (`quick_check.py` warns): no Android equivalent
  without Play Services, and nothing in the backend reads them.
- **The barometer check doesn't block Start:** many Android phones have none.
- **`perm.motion` always passes:** Android has no such permission.
- **Background:** a foreground service (type `location`) and a wake lock keep recording; after Stop it stays
  (type `dataSync`) until the upload queue is empty. Swiping the app away does not end the trip (iOS ends it
  cleanly); opening Bumpy shows it again. A killed app's trip is recovered on the next launch, as on iOS.
- **"Low Power Mode" reads "Battery Saver"**, and settings paths are Android's.
- **The navigation bar stays visible** while recording: hiding it makes Android cover the screen with a notice.
- **The live roughness and sickness estimates are not ported:** no screen shows them since D51.
- **`session.json`** adds `device.platform` and `device.osVersion`; `device.iosVersion` holds the Android version.
- **Cleartext http** is allowed by the manifest and refused by `UploadConfig.parseBaseUrl` for anything but a
  local test server, the same rule as iOS.

## Not verified yet

Run on an emulator (Android 17) against the mock server. Not yet on a real phone, not against Azure, and not
next to the iPhone. Also untried: the Files app entry, swiping the app away mid-trip, and uploads that go on after
Stop with the screen off. Before trusting a phone model: mount it beside the iPhone, drive the same trip and compare
roughness, MSDV and events.

## Tests

```bash
./gradlew :app:testDebugUnitTest
python -I tools/check_contract.py   # runs what the tests wrote through the real ingest validator
```

`.github/workflows/android-app.yml` runs both, lint and the release build, also when the iPhone fixtures or the
ingest validator change. JVM tests of the data path, ported from the iOS app's. They compare against `../mobile-ios/tools/fixtures`
and never write there.

## Code map

```
app/src/main/java/com/chuds/sensorrecorder/
  app/        process-wide AppModel, activity, foreground service, settings and key storage, Files-app provider
  core/       clocks, CSV, JSON, session files and writers, session.json, recovery, rates/gaps, warning rules
  sensors/    Android sensors and GPS → iOS units and signs (MotionFusion)
  recording/  one recording, its 8 Hz view model, preflight, trip summary
  upload/     batches, disk queue, HTTP, what reached the cloud
  ui/         Start, Recording, Recap, menu, Settings
```

Libraries: AndroidX Compose (ui, foundation), activity-compose and kotlinx-coroutines, for the UI. The data
path uses none. Geist is under the SIL Open Font License (`Geist-OFL.txt`).
