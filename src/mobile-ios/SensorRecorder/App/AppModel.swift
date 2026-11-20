import Foundation
import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
    case setup
    case preflight
    case detail(String) // folder name
    case settings
    case help
}

/// App-wide state and long-lived services. Main actor.
@MainActor
@Observable
final class AppModel {
    let store: SessionStore
    let location = LocationService()
    let deviceMonitor = DeviceStatusMonitor()
    let audio = AudioRecorderService()
    let audioMeter = AudioLevelMeterService()
    let uploadQueue: UploadQueue
    let sicknessInterval: TimeInterval
    let sicknessTimeout: TimeInterval

    var sessions: [SessionStore.Entry] = []
    var path = NavigationPath()
    var setup: SessionSetup
    var recording: RecordingController?
    var lastRecoveredCount = 0
    /// Read from the upload loop's background thread.
    @ObservationIgnored let activeSession = Locked<RecordingSession?>(nil)
    var isRecovering = false

    init() {
        let args = AppInfo.arguments
        store = SessionStore.default
        if args.contains("-uiTestingReset") {
            let docs = SessionStore.documentsDirectory
            for name in ["sessions", "upload_queue", "upload_failed"] {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
            }
            UserDefaults.standard.removeObject(forKey: SetupDefaults.key)
        }
        try? store.ensureRoot()
        uploadQueue = UploadQueue(directory: UploadQueue.defaultDirectory, config: { AppSettings.uploadConfig })
        // Launch arguments `-sicknessInterval <s> -sicknessTimeout <s>` (NSArgumentDomain) override
        // the spec defaults (120 s / 30 s); used by UI tests and for dry runs.
        let d = UserDefaults.standard
        let interval = d.double(forKey: "sicknessInterval")
        let timeout = d.double(forKey: "sicknessTimeout")
        sicknessInterval = interval > 0 ? interval : 120
        sicknessTimeout = timeout > 0 ? timeout : 30
        setup = SetupDefaults.load()
        // Upload events go to the active session's app_log.txt (spec §4) and to the unified log.
        let active = activeSession
        // Force-quit / system termination while recording: stop cleanly (final flush, endedAtUtc,
        // stats) instead of leaving a "recovered" session that lost its last half second.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let rec = self?.recording, !rec.isFinished else { return }
                rec.stop()
            }
        }
        uploadQueue.onEvent = { level, msg in
            appLogger.log(level: level == .info ? .info : .error, "\(msg, privacy: .public)")
            active.current?.log(level, msg)
        }
    }

    /// Launch tasks: recover interrupted sessions, list sessions, start the upload loop.
    @ObservationIgnored private var launched = false

    func onLaunch() {
        // .onAppear can fire again if iOS recreates the scene while we keep running in the background.
        guard !launched, !AppInfo.isRunningUnitTests else { return }
        launched = true
        uploadQueue.start()
        isRecovering = true
        let store = self.store
        let active = recording?.session.folder
        Task.detached(priority: .userInitiated) {
            let recovered = store.recoverUnfinishedSessions(excluding: active)
            let list = store.list()
            await MainActor.run {
                self.lastRecoveredCount = recovered.count
                self.sessions = list
                self.isRecovering = false
            }
        }
    }

    func refreshSessions() {
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let list = store.list()
            await MainActor.run { self.sessions = list }
        }
    }

    /// A fresh motion source (for the preflight motion test).
    func makeMotionSource() -> MotionSource { CoreMotionSource() }

    /// All real sensor sources for one recording.
    func makeDependencies() -> RecordingSession.Dependencies {
        RecordingSession.Dependencies(
            motion: CoreMotionSource(), location: location, altimeter: CoreAltimeterSource(),
            activity: CoreActivitySource(),
            // Audio OFF (default on bus/tram, GDPR): level meter only, nothing from the mic is stored.
            audio: setup.audioEnabled ? audio : audioMeter,
            deviceStatus: deviceMonitor, uploadQueue: uploadQueue,
            deviceId: AppSettings.deviceId, appVersion: AppInfo.version, deviceInfo: AppInfo.deviceInfo)
    }

    // MARK: Recording

    func startRecording(preflight: SessionMetadata.Preflight?) throws {
        guard recording == nil else { return }
        // Launch recovery marks unfinished sessions; never let it see a session we are creating.
        guard !isRecovering else {
            throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "Still checking previous sessions, try again in a second."])
        }
        SetupDefaults.save(setup)
        let deps = makeDependencies()
        let session = try RecordingSession(store: store, setup: setup, preflight: preflight, deps: deps)
        let controller = RecordingController(session: session, sicknessInterval: sicknessInterval,
                                             sicknessTimeout: sicknessTimeout)
        location.stopPreview()
        recording = controller
        activeSession.withLock { $0 = session }
        controller.start()
        uploadQueue.kick()
    }

    /// Called from the summary screen's "Done".
    func closeRecording() {
        activeSession.withLock { $0 = nil }
        recording = nil
        setup.mountPhotoJPEG = nil
        path = NavigationPath()
        refreshSessions()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard let rec = recording, !rec.isFinished else { return }
        switch phase {
        case .background: rec.session.noteLifecycle(background: true)
        case .active: rec.session.noteLifecycle(background: false)
        default: break
        }
    }
}

/// Remembers the last setup form (minus the photo) so a new session takes seconds.
enum SetupDefaults {
    static let key = "setup.last"

    private struct Stored: Codable {
        var vehicle: SessionMetadata.Vehicle
        var mount: SessionMetadata.Mount
        var people: SessionMetadata.People
        var conditions: SessionMetadata.Conditions
        var audioEnabled: Bool? // optional: older stored setups lack it
    }

    static func load() -> SessionSetup {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return SessionSetup() }
        var setup = SessionSetup(vehicle: s.vehicle, audioEnabled: s.audioEnabled ?? !s.vehicle.isPublicTransport,
                                 mount: s.mount, people: s.people, conditions: s.conditions)
        setup.mount.photoFile = nil
        return setup
    }

    static func save(_ setup: SessionSetup) {
        let s = Stored(vehicle: setup.vehicle, mount: setup.mount, people: setup.people, conditions: setup.conditions,
                       audioEnabled: setup.audioEnabled)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }
}
