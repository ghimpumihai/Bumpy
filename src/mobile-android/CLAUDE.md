# Android Sensor Recorder rules

A port of `src/mobile-ios` (D58). Its `CLAUDE.md` rules on the contract, files on disk, upload, UI and real data apply here too; a behaviour change goes into both apps. Only the differences are below.

- **iOS semantics everywhere.** Units, axes and signs are converted in `sensors/` and nowhere else. Never feed `TYPE_GRAVITY` or `TYPE_LINEAR_ACCELERATION` into `deviceMotion` (D46, README).
- **Layers:** `ui → app → recording → (core, sensors, upload)`. `core/`, `upload/`, `RecordingSession` and `MotionFusion` use no Android classes, so the data path is tested on the JVM.
- **Dependencies:** AndroidX Compose and coroutines for the UI, none in the data path. No Play Services. Ask before adding one.
- **JSON integers stay Int/Long** (`batchSeq`, `t0UtcMs`, `tUtcMs`, …): the ingest validator rejects `1.0`.
- **Scheduled tasks catch Throwable:** an exception that escapes silently cancels every later run.
- **Every source's `stop()`** guarantees no callback after it returns: writers are closed right after.
- **The notification never gets a Stop action:** Stop is a 2 s hold.
- **Intent extras are read in debug builds only:** any app can send them, and a changed server address would take the trips and the device key.
- **Locale:** numbers and dates that leave the app go through `Csv`, `Json` and `ISO8601`, or `String.format(Locale.US/ROOT, …)`.
- Every interactive control has a `testTag` with the iOS `accessibilityIdentifier`'s name.

Done means `./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleRelease` passes and `python -I tools/check_contract.py` says OK.
