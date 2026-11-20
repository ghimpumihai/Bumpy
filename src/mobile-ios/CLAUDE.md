---
description: iOS app architecture and conventions — App → UI → Recording → Core/Sensors/Upload layering, SwiftUI + Observation, threading, on-disk data contract, Theme tokens, testing
globs: src/mobile-ios/**/*.swift,src/mobile-ios/**/*.plist,src/mobile-ios/**/*.xcscheme,src/mobile-ios/**/*.pbxproj,src/mobile-ios/tools/**/*.py
alwaysApply: false
scope: This rule applies ONLY to `src/mobile-ios/` in the DataInfrastructure_Chuds repository. Do not apply it anywhere else.
---

# Mobile app — iOS Sensor Recorder

## Project Description

You are a Principal iOS Engineer and Swift architect with 15+ years of experience building
production iOS apps, with deep knowledge of CoreMotion, CoreLocation, AVFoundation and
real-time data capture.

This is the iPhone data-collection app of the Codelap Hackathon 2026 project (Porsche Engineering,
"Data-Driven Infrastructure Engineering"). It records every useful sensor of an iPhone 14 Pro at
the highest practical rate, **writes everything to local files first**, optionally uploads gzipped
batches to the AWS backend, and shows a live health dashboard. The single source of requirements is
[`decisions/01-initial-plan.md`](../../decisions/01-initial-plan.md) (backend plan:
[`02-infrastructure-plan.md`](../../decisions/02-infrastructure-plan.md)); user-facing docs are in
[`README.md`](README.md).

There is **ONE real test drive**. Every decision favours: over-collect, local-first, visible health,
hard to break. Losing data is the worst possible bug; a red banner is better than silent failure.

The backend (AWS API Gateway + ingest Lambda, see 02) is built by teammates. The app's contract is
`POST {API}/api/ingest` (gzip JSON, spec §6); there is no health route, so connectivity is tested
with a probe POST. `tools/mock_ingest_server.py` stands in for it locally. Do **not** write
backend, processing or web-dashboard code in this folder.

## Tech Stack

- Swift (Swift 5 language mode on the Swift 6 toolchain), SwiftUI, Observation (`@Observable`)
- iOS 17+ deployment target, iPhone only, portrait only
- CoreMotion, CoreLocation, AVFoundation (`AVAudioRecorder`, `AVAudioSession`), MapKit (SwiftUI `Map`),
  Network (`NWPathMonitor`), Compression (raw DEFLATE → our gzip), Security (Keychain), PhotosUI
- XCTest (unit) + XCUITest (UI), run on the iOS Simulator
- Xcode project with file-system-synchronized groups (`objectVersion 77`): new files in
  `SensorRecorder/`, `SensorRecorderTests/`, `SensorRecorderUITests/` are picked up automatically —
  never add per-file entries to `project.pbxproj`
- Python 3 standard library only for `tools/`
- **No third-party dependencies** (no SPM/CocoaPods) unless the team explicitly approves one.

## General Principles

Always produce production-ready code.

Prioritize:

- Data integrity and crash-safety (above everything else)
- Clean Architecture, SOLID, composition over inheritance
- Separation of concerns, small focused types
- Type safety and thread safety
- Accessibility (VoiceOver, contrast, large hit targets for use in a moving car)
- Performance (thermal headroom: the phone sits on a dashboard for an hour)
- Testability, maintainability

Never write quick hacks. If multiple approaches exist, explain the trade-offs and recommend the best one.

---

## SwiftUI Guidelines

- Views are structs, small and single-purpose. Split a screen into subviews when one part changes
  at a different rate (e.g. the map reads only `trackPoints`, updated ≤ 1 Hz, so it never re-renders
  with the 8 Hz table).
- State lives in `@Observable` models (`AppModel`, `RecordingController`, `PreflightModel`), never in
  the view beyond pure UI state (`@State` for a sheet flag, focus, text being typed).
- Read observable properties in the narrowest subview that needs them; Observation tracks per property.
- No work in `body`: no I/O, no sorting large arrays, no formatter allocation per sample.
- The UI refreshes at 5–10 Hz from **snapshots**; never push per-sample updates to the main thread.
- Derive state instead of duplicating it. Do not mirror model state in `@State`.
- Use `.task`/`.onAppear` only for real lifecycle work (start/stop previews, load a list); no
  side-effects that duplicate model logic.
- Use `@ObservationIgnored` for non-UI internals inside `@Observable` classes.

---

## Swift Guidelines

- No force unwraps (`!`) or `try!` in production code, except for true programmer invariants with a
  comment explaining why they cannot fail.
- No `Any`/`AnyObject` in our own APIs (framework dictionaries such as `AVAudioRecorder` settings excepted).
- Closed sets are `enum`s (String raw values when persisted, e.g. `LabelType`, `StreamFile`); use
  enums with associated values for outcomes (`UploadQueue.Outcome`) instead of flags + optionals.
- Contracts are protocols (`MotionSource`, `LocationSource`, `AudioSource`, `HTTPTransport`,
  `ClockSource`, …) so hardware can be replaced by mocks/fakes.
- Prefer value types for data (`DeviceMotionSample`, `LocationSample`, `IngestBatch`); classes only
  for identity/lifecycle (sessions, services, writers).
- Every `Codable` contract type that leaves the app (session.json, ingest JSON) has explicit
  `CodingKeys`/`encode(to:)` wherever null-vs-omitted matters, and a test that pins its keys.

### Where types live

- Sensor sample types and source protocols: `Sensors/SensorTypes.swift`.
- Session, storage, time, health and stream-statistics types: `Core/`.
- Upload payload/config/status types: `Upload/`.
- Screen-level view models and their pure helpers: `Recording/`.
- `UI/` files contain views only. View-private helper types (`StreamRowModel.Dot`, a sheet's local
  enum) may stay `private` in the view file; anything another layer uses moves to its domain folder.

---

## Architecture: App → UI → Recording → Core / Sensors / Upload

```text
src/mobile-ios/
├── Config/Info.plist            # Permissions strings, background modes, file sharing (hand-maintained)
├── SensorRecorder/
│   ├── App/                     # Entry point, AppModel (services + navigation), AppInfo
│   ├── UI/                      # SwiftUI screens and components; Theme tokens
│   ├── Recording/               # RecordingSession (the pipeline), RecordingController (dashboard VM),
│   │                            # PreflightModel, LiveSignals, SicknessScheduler
│   ├── Core/                    # Pure Foundation logic: TimeBase, CSV, SessionFiles (schemas + writers),
│   │                            # SessionMetadata, SessionStore (recovery), StreamMonitor, HealthEvaluator
│   ├── Sensors/                 # Hardware adapters (CoreMotion, CoreLocation, AVAudio, device health)
│   └── Upload/                  # IngestBatch + accumulator, Gzip, UploadQueue, settings/Keychain
├── SensorRecorderTests/         # XCTest unit + integration tests
├── SensorRecorderUITests/       # XCUITest end-to-end flows
└── tools/                       # quick_check.py, mock_ingest_server.py (stdlib only)
```

### Layer responsibilities and dependency direction

`UI → Recording → (Core, Sensors, Upload)`; `Sensors`/`Upload` may use `Core`; **`Core` never
imports SwiftUI or UIKit** and never touches hardware frameworks.

- **App/** — composition root: creates long-lived services and the sensor sources for a
  recording (`AppModel.makeDependencies()`). No business logic.
- **UI/** — renders model state and forwards user intents. No file I/O, no networking, no sensor
  APIs, no thresholds. Screens: Sessions → Setup → Preflight → Recording dashboard → Summary,
  plus Session detail, Settings, Help.
- **Recording/** — orchestration and view models. `RecordingSession` is the only place that wires
  sensor callbacks to writers, monitors and the batch accumulator.
- **Core/** — pure, deterministic, unit-tested logic. The on-disk schema lives **only** in
  `StreamFile` (`SessionFiles.swift`).
- **Sensors/** — thin adapters that convert framework objects into our sample value types
  immediately. No business logic.
- **Upload/** — all network access (`URLSession` only via `HTTPTransport`). Views never call the network.

### Add a new sensor stream (the analogue of "create a new route")

1. Add the sample value type and, if needed, a source protocol in `Sensors/SensorTypes.swift`.
2. Implement the adapter in `Sensors/` (convert framework objects to the sample type immediately)
   and a fake for tests in `SensorRecorderTests/TestSupport.swift`.
3. Add a `StreamFile` case with its exact header, and a `StreamID` (rate, window, display name).
4. Wire it in `RecordingSession` (write row + `StreamMonitor.record`) and in
   `AppModel.makeDependencies()`.
5. Add health rules (if any) to `HealthEvaluator` with a test per rule, and a dashboard row.
6. Update `decisions/01-initial-plan.md`/`README.md` (file table), `tools/quick_check.py` (expected header),
   and the header-pinning test.

---

## Threading & Real-time Rules

- Sensor callbacks run on dedicated background queues (`OperationQueue`/`DispatchQueue`), never main.
- The main thread only renders. Never block it on I/O or wait for sensor queues except in `stop()`.
- All shared mutable state is behind `Locked<T>` (or confined to one serial queue). Document which.
- Never `sync` onto the queue you are running on. Lock order must be consistent.
- Every source's `stop()` must guarantee **no callback after it returns** (drain the queue), because
  writers are closed right after.
- One `CMMotionManager` for the whole app (`SharedMotion`). Nothing may start motion updates while
  a recording owns them (preflight checks `app.recording == nil`; Start is disabled while checks run).
- `CLLocationManager` lives on main; `AVAudioRecorder` is used only on the audio service's queue.

---

## Data Contract (local-first)

- Files are **append-only**, buffered, flushed every ≤ 1 s (`SessionWriter`); `session.json` is
  written atomically. A crash must lose at most ~1 s; unfinished sessions are recovered on launch.
- Store **native iOS units**; no conversions in the app. Every sensor CSV starts with `t_up`
  (seconds since boot, 6 decimals) and `t_utc_ms` (from `TimeBase` anchors). Lat/lon 8 decimals.
- Format numbers only through `CSV` helpers (locale-independent `.`); dates through `ISO8601`;
  sizes/durations through `ByteFormat`/`DurationFormat`. No ad-hoc `String(format:)` for file output.
- Never rename or reorder existing columns; only append new ones at the end. Any schema change
  updates spec/README, `quick_check.py` and the tests in the same change.
- Raw audio is never uploaded. With `audioEnabled == false` (default on bus/tram, GDPR) no audio
  is written at all — only the level meter runs.
- `session.json` must stay decodable across app versions: new keys are decoded with
  `decodeIfPresent` + defaults, and a test decodes an old-format file.

## Upload Layer (analogue of the data-fetching layer)

- All network code in `Upload/`. Batches are built every 2 s and queued on disk first; the queue
  uploads one request at a time, oldest first, backoff 1 → 30 s, 2xx/409 = done.
- Idempotency key `sessionId:batchSeq`. Never duplicate or drop samples between batches.
- Secrets (device key) only in the Keychain; the API URL in UserDefaults; nothing in the repo.
- Upload problems are WARN at most — data is safe on disk.

## Forms & Settings (analogue of RHF + Zod)

- Validation lives in model/types code (`UploadConfig.parseBaseURL`, `SessionSetup` defaults),
  never duplicated in views. Views show the validation result.
- Defaults must make setup take ~30 s (`SetupDefaults` remembers the last session).

---

## Styling

- Colors only through `Theme` tokens (`ok`, `warn`, `problem`, `neutral`, `panel`, `accent`,
  `labelSpeedBump`, `speedBuckets`, `onBright`, `onSurface`, `scrim`, …). Never raw palette colors
  (`.red`, `Color.orange`, `.white`) in views; add a token instead.
- Status colors mean exactly: green OK, amber WARN, red PROBLEM, grey neutral/off ("UPLOAD OFF" is grey).
- Dark, high-contrast UI readable in sunlight; monospaced digits for live numbers
  (`Theme.mono`). Large hit targets (≥ 44 pt; label buttons ≥ 52–60 pt) for use in a moving car.
- Destructive actions need confirmation (`confirmationDialog`/`alert`); Stop is a 2 s long-press —
  never add a single-tap stop or a pause.

### Accessibility

- Every interactive control has an `accessibilityIdentifier` (UI tests depend on them) and a
  meaningful label; icon-only buttons get `accessibilityLabel`.
- **Never put `accessibilityIdentifier` on a container** (stack/overlay/List): SwiftUI propagates it
  to children and overwrites their identifiers.
- Toggles expose state via `accessibilityValue` ("active"/"inactive"); the health banner exposes
  OK/WARN/PROBLEM.
- Maintain ≥ 4.5:1 contrast for text (use `onBright` text on amber/green surfaces).

---

## Project Conventions

### Files and code style

- File names are UpperCamelCase and match the primary type (`RecordingSession.swift`);
  extensions are `Type+Feature.swift`. (Swift convention — not kebab-case.)
- One primary type per file; small private helpers may share the file.
- Constants: thresholds and rates are named `static let` on the type that owns the rule
  (`HealthEvaluator.gpsProblemAge`, `PreflightModel.minMotionRate`, `SessionWriter.flushInterval`).
  No magic numbers in logic; layout literals (padding, corner radius) in views are fine.
- Comments explain *why* (non-obvious decisions, spec references like "spec §5"), not *what*.
- UI copy is English (hackathon jury); there is no localization.

### Real data only

- The app ships **real sensors only** — no mock/demo data mode. Synthetic sources and fakes live
  in the test target only. Never add a code path that can silently record non-real data.
- The Simulator has no motion/barometer hardware: there, those streams show "n/a" and preflight
  needs the (recorded) override. Real data is collected on the iPhone 14 Pro.

---

## Testing

- Every change to pure logic (`Core/`, `Upload/`, `Recording/` helpers) comes with a
  unit test; every spec rule (warning thresholds, upload status mapping, schema) is pinned by a test.
- Integration tests run a real `RecordingSession` with fakes/mocks and inspect the files on disk.
- UI tests run on the Simulator with real (absent) motion hardware and take the preflight override.
- Useful launch arguments: `-uiTesting`, `-uiTestingReset`, `-sicknessInterval <s>`,
  `-sicknessTimeout <s>`, `-upload.baseURL <url>`.

```bash
cd src/mobile-ios
xcodebuild -project SensorRecorder.xcodeproj -scheme SensorRecorder \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test          # all tests
xcodebuild ... -only-testing:SensorRecorderTests test                     # unit only
python3 tools/mock_ingest_server.py --port 8765 --out /tmp/ingest         # local backend stand-in
python3 tools/quick_check.py <exported session folder>                    # dry-run verifier
```

A change is done only when it builds for device (`-sdk iphoneos CODE_SIGNING_ALLOWED=NO`) with
zero warnings and all tests pass.

---

## Before writing code

Always think like a Senior Engineer:

- What happens on a crash, a kill, a phone call, a full disk, no network, a hot phone, Low Power Mode?
- Which queue does this run on, and what else touches this state?
- Does this change the on-disk or upload contract? Then update spec, tools and tests together.
- Is it accessible and usable by a passenger in a moving car?

If a request can be improved, explain why and propose a better implementation before generating code.

When returning code: complete files or exact edits, meaningful names, no omitted sections.
