import Foundation
import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
    case settings
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

    var sessions: [SessionStore.Entry] = []
    var path = NavigationPath()
    var setup: SessionSetup
    var recording: RecordingController?
    var lastRecoveredCount = 0
    /// The session whose app_log.txt receives upload events (spec §4). It stays set after Stop and
    /// after Done — the final batches and the Stop metadata upload later — until the next recording
    /// starts or the session is deleted. Read from the upload loop's background thread.
    @ObservationIgnored let uploadLogSession = Locked<RecordingSession?>(nil)
    var isRecovering = false

    init() {
        let args = AppInfo.arguments
        store = SessionStore.default
        #if DEBUG && targetEnvironment(simulator)
        // UI tests only, and only on the Simulator: ⌘U with the drive iPhone selected (a Debug
        // build) must never be able to delete recorded sessions.
        if args.contains("-uiTestingReset") {
            let docs = SessionStore.documentsDirectory
            for name in ["sessions", "upload_queue", "upload_failed"] {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
            }
            UserDefaults.standard.removeObject(forKey: SetupDefaults.key)
            UserDefaults.standard.removeObject(forKey: AppSettings.roadNoiseKey)
        }
        #endif
        try? store.ensureRoot()
        uploadQueue = UploadQueue(directory: UploadQueue.defaultDirectory, config: { AppSettings.uploadConfig })
        setup = SetupDefaults.load()
        // Upload events go to the latest session's app_log.txt (spec §4) and to the unified log.
        let logTarget = uploadLogSession
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
            logTarget.current?.log(level, msg)
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
            // Zips left in tmp/ by an export that never finished (app killed with the share sheet open).
            FolderZipper.removeStaleExports()
            let recovered = store.recoverUnfinishedSessions(excluding: active)
            let list = store.list()
            await MainActor.run {
                self.lastRecoveredCount = recovered.count
                self.sessions = list
                self.isRecovering = false
            }
        }
    }

    enum DeleteSessionError: LocalizedError {
        case batchesNotUploaded(Int)

        var errorDescription: String? {
            switch self {
            case .batchesNotUploaded(let count):
                return "\(count) batch(es) of this trip haven't reached the cloud yet. Let the upload finish before deleting."
            }
        }
    }

    /// Deletes a recorded session. Refuses the session being recorded, and a session whose batches are
    /// still queued: a trip is deleted from the phone only once it reached the cloud.
    func deleteSession(folder: URL, sessionId: String?) async throws {
        if let active = recording?.session.folder, active.standardizedFileURL == folder.standardizedFileURL,
           recording?.isFinished == false {
            throw CocoaError(.fileWriteNoPermission)
        }
        uploadLogSession.withLock { s in
            if s?.folder.standardizedFileURL == folder.standardizedFileURL { s = nil }
        }
        let store = self.store, queue = uploadQueue
        try await Task.detached(priority: .userInitiated) {
            if let sessionId {
                let pending = queue.pendingCount(sessionId: sessionId)
                if pending > 0 { throw DeleteSessionError.batchesNotUploaded(pending) }
            }
            try store.deleteSession(folder)
        }.value
        refreshSessions()
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
        // D51: no setup form. Every trip is a car; mount and people keep the remembered defaults.
        setup.vehicle = SessionMetadata.Vehicle()
        setup.audioEnabled = AppSettings.recordRoadNoise
        SetupDefaults.save(setup)
        let deps = makeDependencies()
        let session = try RecordingSession(store: store, setup: setup, preflight: preflight, deps: deps)
        let controller = RecordingController(session: session)
        location.stopPreview()
        recording = controller
        uploadLogSession.withLock { $0 = session }
        controller.start()
        uploadQueue.kick()
    }

    /// Called from the summary screen's "Done".
    /// `uploadLogSession` is kept: this session's last uploads may still be in flight.
    func closeRecording() {
        recording = nil
        setup.mountPhotoJPEG = nil
        path = NavigationPath()
        refreshSessions()
    }

    /// `.active` also follows inactive-only trips (Control Center, alerts); the session ignores a
    /// "foreground" note unless it was really in the background.
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
        // Bus/tram always start with audio OFF (spec §3.5, GDPR), whatever the last trip used.
        let audio = s.vehicle.isPublicTransport ? false : (s.audioEnabled ?? true)
        var setup = SessionSetup(vehicle: s.vehicle, audioEnabled: audio,
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
