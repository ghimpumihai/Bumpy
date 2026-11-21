---
description: iOS app rules — backend contract, project file, layers, threading, on-disk data contract, upload queue, UI and testing
globs: src/mobile-ios/**/*.swift,src/mobile-ios/**/*.plist,src/mobile-ios/**/*.xcscheme,src/mobile-ios/**/*.pbxproj,src/mobile-ios/tools/**/*.py
alwaysApply: false
scope: This rule applies ONLY to `src/mobile-ios/` in the DataInfrastructure_Chuds repository. Do not apply it anywhere else.
---

# iOS Sensor Recorder rules

Requirements: `decisions/01-initial-plan.md`. Losing data is the worst possible bug; a red banner beats a silent failure.

## Scope and contract
- Backend contract: `POST {API}/api/ingest` (gzip JSON, spec §6) and `PUT {API}/api/ingest/sessions/{id}` (`session.json` at Start and Stop, §6.1). There is no health route: connectivity is tested with a probe POST. `tools/mock_ingest_server.py` stands in for the backend locally.
- Don't write backend, processing or dashboard code in this folder.
- No third-party dependencies unless the team approves one. `tools/` is Python standard library only.

## Project file
- The Xcode project uses file-system-synchronized groups (`objectVersion 77`): new files in `SensorRecorder/`, `SensorRecorderTests/`, `SensorRecorderUITests/` are picked up automatically. Never add per-file entries to `project.pbxproj`.

## Layers
- `UI → Recording → (Core, Sensors, Upload)`; `Sensors` and `Upload` may use `Core`; `Upload` may also use the sample value types in `Sensors/SensorTypes.swift`. `Core` never imports SwiftUI/UIKit or hardware frameworks.
- `RecordingSession` is the only place that wires sensor callbacks to writers, monitors and the batch accumulator.
- All network access in `Upload/`, through `HTTPTransport`.
- The on-disk schema lives only in `StreamFile` (`SessionFiles.swift`).
- Adding a sensor stream touches: the sample type and source protocol (`Sensors/SensorTypes.swift`), an adapter plus a fake in `SensorRecorderTests/TestSupport.swift`, a `StreamFile` case with its exact header and a `StreamID`, wiring in `RecordingSession` and `AppModel.makeDependencies()`, health rules in `HealthEvaluator` with tests, then the spec/README file table, `tools/quick_check.py` and the header-pinning test.

## Threading
- Sensor callbacks run on background queues; the main thread only renders. The UI refreshes at 5–10 Hz from snapshots, never per sample.
- Shared mutable state is behind `Locked<T>` or confined to one serial queue; document which.
- Every source's `stop()` guarantees no callback after it returns (drain the queue): writers are closed right after.
- One `CMMotionManager` for the app (`SharedMotion`). Nothing may start motion updates while a recording owns them (preflight checks `app.recording == nil`).
- `CLLocationManager` lives on main; `AVAudioRecorder` is used only on the audio service's queue.

## Files on disk
- Append-only, flushed every ≤ 1 s (`SessionWriter`); `session.json` written atomically. Unfinished sessions are recovered on launch.
- Native iOS units, no conversions. Every sensor CSV starts with `t_up` (seconds since boot, 6 decimals) and `t_utc_ms` (from `TimeBase` anchors); lat/lon 8 decimals.
- Format CSV data columns only through the `CSV` helpers (locale-independent), dates through `ISO8601`; no ad-hoc `String(format:)` for them.
- Never rename or reorder columns; only append. A schema change updates spec/README, `quick_check.py` and the tests in the same change.
- `tools/fixtures/` (ingest batch + `csv_headers.json`) is the cross-language contract: tests compare, never rewrite. Regenerate only on purpose: `TEST_RUNNER_REGENERATE_FIXTURES=1 xcodebuild … test`.
- `session.json` must stay decodable across app versions: new keys use `decodeIfPresent` with defaults, and a test decodes an old-format file.
- Contract types that leave the app (`session.json`, ingest JSON) use explicit `CodingKeys`/`encode(to:)` where null vs omitted matters, with a test that pins their keys.
- Raw audio is never sent live. With `audioEnabled == false` (default on bus/tram, GDPR) no audio is written; only the level meter runs.

## Upload
- Batches are built every 2 s and queued on disk before sending; one request at a time, oldest first, backoff 1 → 30 s. Any 2xx means done; 409 is also handled as done, though the Azure backend answers 200 for duplicates and never sends 409. Idempotency key `sessionId:batchSeq`; never drop or duplicate samples between batches.
- Device key only in the Keychain, API URL in UserDefaults, nothing in the repo.
- Upload problems are WARN at most: the data is safe on disk.

## UI
- Colours only through `Theme` tokens. Status colours mean exactly: green OK, amber WARN, red PROBLEM, grey neutral/off ("UPLOAD OFF" is grey).
- Stop is a 2 s long-press. Never add a single-tap stop or a pause.
- Every interactive control has an `accessibilityIdentifier` (UI tests rely on them). Never put one on a container: SwiftUI propagates it and overwrites the children's. Toggles expose state through `accessibilityValue` ("active"/"inactive").
- Hit targets ≥ 44 pt, label buttons 52–60 pt (used in a moving car).
- Validation lives in model types (`UploadConfig.parseBaseURL`, `SessionSetup`), not views. `SetupDefaults` remembers the last session so setup takes ~30 s.
- UI copy is English.

## Real data only
The app ships real sensors only: no mock or demo mode. Fakes live in the test target. The Simulator has no motion/barometer hardware: those streams show "n/a" and preflight needs the recorded override.

## Testing
- Tests are required where data can be lost: `Upload/`, the on-disk schema (`StreamFile`, `SessionWriter`), `session.json` and the contract types. Elsewhere, skip them.
- Launch arguments: `-uiTesting`, `-uiTestingReset`, `-sicknessInterval <s>`, `-sicknessTimeout <s>`, `-upload.baseURL <url>`.

```bash
xcodebuild -project SensorRecorder.xcodeproj -scheme SensorRecorder \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
python3 tools/mock_ingest_server.py --port 8765 --out /tmp/ingest
python3 tools/quick_check.py <exported session folder>
```

Done means it builds for device (`-sdk iphoneos CODE_SIGNING_ALLOWED=NO`) with no new warnings and all tests pass. Never silence a concurrency warning with `@unchecked Sendable` or `nonisolated(unsafe)` to get there.
