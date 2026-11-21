import AVFoundation
import Foundation
import UIKit

/// Audio recording (S2) + 10 Hz level meter (S1).
///
/// Design notes
/// - Session: `.playAndRecord` + mode `.measurement` (no AGC / voice processing, spec §3.5). We use
///   playAndRecord instead of `.record` only so the alert sounds can still play.
/// - Input is pinned to the built-in mic so a car Bluetooth hands-free system can't hijack it.
/// - Files are written as **segments** (`audio_000.m4a`, `audio_001.m4a`, …) of 5 minutes. An
///   AAC/MP4 file is only playable once `stop()` writes its index, so a crash or kill would
///   otherwise destroy the whole drive's audio. With segments we lose at most the current one.
///   Rotation starts the next recorder before stopping the previous one (overlap, no gap).
///   Each segment start is logged with its uptime (`clock.csv source=audio_start`, and
///   `audio_segments.csv`), so every file maps linearly onto the sensor clock.
/// - After an interruption (phone call, Siri) a *new* segment is started rather than resuming
///   the old file, which keeps that mapping exact.
/// - Background limits: after an interruption while the app is backgrounded (screen locked), iOS
///   may refuse to start mic capture until the app is in the foreground again
///   (`AVAudioSession.ErrorCode.cannotStartRecording`). Then the gap is recorded once
///   (`audio_segments.csv` event `blocked_background`, PROBLEM in app_log.txt), retries slow down to
///   `AudioSegmentPolicy.backgroundRetryEvery`, and the next foreground transition restarts at once.
final class AudioRecorderService: NSObject, AudioSource, AVAudioRecorderDelegate {
    static let segmentDuration: TimeInterval = 300
    static let meterInterval: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "sensorrecorder.audio", qos: .userInitiated)
    // Everything below is confined to `queue` (except `shared`, which is locked).
    private var recorder: AVAudioRecorder?
    private var currentFile: String?
    private var segmentIndex = -1
    private var segmentStartedUp: TimeInterval = 0
    private var folder: URL?
    private var callbacks = AudioCallbacks()
    private var meterTimer: DispatchSourceTimer?
    private var wantRecording = false
    private var interrupted = false
    private var interruptedAtUp: TimeInterval = 0
    /// iOS does not guarantee an "interruption ended" notification; retry anyway after this long.
    static let interruptionRetryAfter: TimeInterval = 20
    private var lastRestartAttemptUp: TimeInterval = 0
    private var lastRotateAttemptUp: TimeInterval = -.infinity
    /// Mirrors UIApplication's state (updated from its notifications).
    private var appInBackground = false
    /// A restart failed while backgrounded: iOS will most likely only allow it in the foreground.
    private var blockedInBackground = false
    /// Failed restart attempts since recording last ran (only the first one of a streak is logged).
    private var failedRestarts = 0
    /// Uptime at which audio stopped being recorded (nil while recording).
    private var gapStartedUp: TimeInterval?
    private var observers: [NSObjectProtocol] = []
    private var meterTicks = 0
    private let shared = Locked<(recording: Bool, level: AudioLevelSample?, bytes: Int64)>((false, nil, 0))

    let formatDescription = "AAC 48 kHz mono 64 kbps"
    var recordsAudio: Bool { true }

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    var isRecording: Bool { shared.current.recording }
    var latestLevel: AudioLevelSample? { shared.current.level }
    var bytesWritten: Int64 { shared.current.bytes }

    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static var permissionUndetermined: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined
    }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    @discardableResult
    func start(folder: URL, _ callbacks: AudioCallbacks) -> Bool {
        let background = Self.appIsInBackground()
        return queue.sync {
            // This service outlives a session: reset all per-session state.
            self.folder = folder
            self.callbacks = callbacks
            self.wantRecording = true
            self.recorder = nil
            self.currentFile = nil
            self.segmentIndex = -1
            self.segmentStartedUp = 0
            self.interrupted = false
            self.lastRestartAttemptUp = 0
            self.lastRotateAttemptUp = -.infinity
            self.appInBackground = background
            self.blockedInBackground = false
            self.failedRestarts = 0
            self.gapStartedUp = nil
            self.meterTicks = 0
            self.shared.withLock { $0 = (false, nil, 0) }
            installObservers()
            // The meter timer is also the watchdog: start it even if the first attempt fails.
            startMeterTimer()
            if let error = activateSession() {
                callbacks.log(.error, "audio session setup failed: \(Self.describe(error))")
                return false
            }
            if let failure = startNewSegment(allowStopFallback: true) {
                callbacks.log(.error, failure)
                return false
            }
            return true
        }
    }

    func stop() {
        queue.sync {
            wantRecording = false
            meterTimer?.cancel()
            meterTimer = nil
            finishCurrentSegment(event: "stop")
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                callbacks.log(.info, "audio session deactivate: \(error.localizedDescription)")
            }
            updateBytes()
            shared.withLock { $0.recording = false }
        }
    }

    /// `start()` runs on the main thread (RecordingSession.start); anything else assumes foreground
    /// until the first UIApplication notification says otherwise.
    private static func appIsInBackground() -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
    }

    // MARK: - Session

    /// - Returns: nil on success, else the error (the caller decides whether to log it).
    private func activateSession() -> Error? {
        let session = AVAudioSession.sharedInstance()
        do {
            try Self.configure(session)
            try session.setActive(true)
            pinBuiltInMic()
            return nil
        } catch {
            return error
        }
    }

    /// Error text including the AVAudioSession code name, e.g. "… (cannotStartRecording)".
    static func describe(_ error: Error) -> String {
        let code = AVAudioSession.ErrorCode(rawValue: (error as NSError).code)
        let name: String
        switch code {
        case .cannotStartRecording: name = "cannotStartRecording"
        case .cannotInterruptOthers: name = "cannotInterruptOthers"
        case .insufficientPriority: name = "insufficientPriority"
        case .isBusy: name = "isBusy"
        case .mediaServicesFailed: name = "mediaServicesFailed"
        default: name = "code \((error as NSError).code)"
        }
        return "\(error.localizedDescription) (\(name))"
    }

    private func pinBuiltInMic() {
        let session = AVAudioSession.sharedInstance()
        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        if session.preferredInput?.uid != mic.uid {
            do { try session.setPreferredInput(mic) } catch {
                callbacks.log(.warn, "could not pin built-in mic: \(error.localizedDescription)")
            }
        }
    }

    /// Shared by the recorder and the level meter.
    /// - `.mixWithOthers`: never stops the phone's music/navigation/CarPlay, and can (re)activate
    ///   while backgrounded (a non-mixable session fails there with `cannotInterruptOthers`).
    /// - Haptics + system sounds are muted by iOS during recording unless explicitly allowed —
    ///   without this the PROBLEM alerts and label haptics would be silent and vibration-free.
    static func configure(_ session: AVAudioSession) throws {
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setPreferredSampleRate(48_000)
        do { try session.setAllowHapticsAndSystemSoundsDuringRecording(true) } catch {
            // Without this the PROBLEM alerts are silent: make it visible.
            appLogger.error("allowHapticsAndSystemSoundsDuringRecording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Segments

    /// Starts the next segment file. With a recorder running, the new one starts first (overlap).
    /// - Parameter allowStopFallback: some routes refuse a second simultaneous recorder; then stop
    ///   the running one and retry. Not used for rotation in the background: if the retry failed
    ///   there, iOS might not let us start again until the app is opened — keep the old one instead.
    /// - Returns: nil on success, else why it failed (not logged here; restarts log once per streak).
    @discardableResult
    private func startNewSegment(allowStopFallback: Bool) -> String? {
        guard let folder else { return "audio: no session folder" }
        let index = segmentIndex + 1
        let file = SessionFileName.audioSegment(index)
        let url = folder.appendingPathComponent(file)
        do {
            let r = try AVAudioRecorder(url: url, settings: Self.settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.prepareToRecord() else {
                try? FileManager.default.removeItem(at: url)
                return "audio prepareToRecord failed for \(file)"
            }
            var ok = r.record()
            var t = ProcessInfo.processInfo.systemUptime // uptime when record() returned (spec §5)
            if !ok, recorder != nil, allowStopFallback {
                finishCurrentSegment(event: "stop")
                ok = r.record()
                t = ProcessInfo.processInfo.systemUptime
            }
            guard ok else {
                try? FileManager.default.removeItem(at: url)
                return "audio record() returned false for \(file)"
            }
            let previous = recorder
            let previousFile = currentFile
            recorder = r
            currentFile = file
            segmentIndex = index
            segmentStartedUp = t
            callbacks.segmentEvent(t, "start", file)
            callbacks.log(.info, "audio segment started: \(file)")
            if let previous, let previousFile {
                previous.stop()
                callbacks.segmentEvent(ProcessInfo.processInfo.systemUptime, "stop", previousFile)
            }
            if let gap = gapStartedUp {
                let attempts = failedRestarts > 0 ? ", after \(failedRestarts) failed attempt(s)" : ""
                callbacks.log(.info, "audio recording again after a \(Int((t - gap).rounded())) s gap\(attempts)")
            }
            gapStartedUp = nil
            failedRestarts = 0
            blockedInBackground = false
            shared.withLock { $0.recording = true }
            return nil
        } catch {
            return "audio recorder creation failed: \(error.localizedDescription)"
        }
    }

    private func finishCurrentSegment(event: String) {
        guard let r = recorder, let file = currentFile else { return }
        r.stop()
        callbacks.segmentEvent(ProcessInfo.processInfo.systemUptime, event, file)
        recorder = nil
        currentFile = nil
    }

    /// One restart attempt (watchdog, interruption ended, foreground, media reset).
    private func attemptRestart(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lastRestartAttemptUp = now
        interrupted = false
        if gapStartedUp == nil { gapStartedUp = now }
        let firstOfStreak = failedRestarts == 0
        if firstOfStreak { callbacks.log(.warn, reason) }
        finishCurrentSegment(event: "stop")
        let failure: String
        if let error = activateSession() {
            failure = "audio session setup failed: \(Self.describe(error))"
        } else if let segmentFailure = startNewSegment(allowStopFallback: true) {
            failure = segmentFailure
        } else {
            return
        }
        failedRestarts += 1
        if firstOfStreak { callbacks.log(.error, failure) }
        if appInBackground && !blockedInBackground {
            blockedInBackground = true
            callbacks.segmentEvent(now, "blocked_background", "")
            callbacks.log(.problem, "audio: iOS does not allow starting the microphone while the app is in the background "
                + "(\(failure)). Audio gap until the app is opened; retrying every \(Int(AudioSegmentPolicy.backgroundRetryEvery)) s "
                + "and immediately when the app comes to the foreground")
        }
    }

    // MARK: - Metering / watchdog

    private func startMeterTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.meterInterval, repeating: Self.meterInterval, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.meterTick() }
        meterTimer = t
        t.resume()
    }

    private func meterTick() {
        meterTicks += 1
        let now = ProcessInfo.processInfo.systemUptime
        let isRec = recorder?.isRecording ?? false
        let action = AudioSegmentPolicy.decide(
            now: now, isRecording: isRec, segmentStartedUp: segmentStartedUp, wantRecording: wantRecording,
            interrupted: interrupted, interruptedAtUp: interruptedAtUp, lastRestartAttemptUp: lastRestartAttemptUp,
            backgroundBlocked: blockedInBackground, lastRotateAttemptUp: lastRotateAttemptUp)
        if let r = recorder, isRec {
            r.updateMeters()
            let s = AudioLevelSample(t: now, avgDbfs: Double(r.averagePower(forChannel: 0)),
                                     peakDbfs: Double(r.peakPower(forChannel: 0)))
            shared.withLock { $0.level = s; $0.recording = true }
            callbacks.level(s)
            if action == .rotate {
                lastRotateAttemptUp = now
                if let failure = startNewSegment(allowStopFallback: !appInBackground) {
                    let keeps = recorder?.isRecording == true ? "; \(currentFile ?? "the current segment") keeps recording" : ""
                    callbacks.log(.warn, "audio segment rotation failed: \(failure)\(keeps), retry in \(Int(AudioSegmentPolicy.rotateRetryEvery)) s")
                }
            }
        } else {
            shared.withLock { $0.recording = false }
            if wantRecording, gapStartedUp == nil { gapStartedUp = now }
            if action == .restart {
                attemptRestart("audio not recording — attempting restart")
            }
        }
        if meterTicks % 10 == 0 { updateBytes() }
    }

    private func updateBytes() {
        guard let folder else { return }
        let fm = FileManager.default
        var total: Int64 = 0
        if segmentIndex >= 0 {
            for i in 0...segmentIndex {
                total += fm.fileSize(folder.appendingPathComponent(SessionFileName.audioSegment(i)))
            }
        }
        shared.withLock { $0.bytes = total }
    }

    // MARK: - Interruptions, media reset, route and app-state changes

    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] n in
            self?.queue.async { self?.handleInterruption(n) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.handleMediaReset() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] n in
            self?.queue.async { self?.handleRouteChange(n) }
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.handleAppState(background: true) }
        })
        // Both: willEnterForeground comes first; if iOS still refuses there, didBecomeActive retries.
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.handleAppState(background: false) }
            })
        }
    }

    private func handleInterruption(_ n: Notification) {
        guard wantRecording,
              let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interrupted = true
            interruptedAtUp = ProcessInfo.processInfo.systemUptime
            if gapStartedUp == nil { gapStartedUp = interruptedAtUp }
            callbacks.log(.warn, "audio interrupted (call/Siri/other app)")
            finishCurrentSegment(event: "interrupted")
            shared.withLock { $0.recording = false }
        case .ended:
            let rawOptions = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            interrupted = false
            if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                attemptRestart("audio interruption ended — starting new segment")
            } else {
                // iOS says not to resume right away (another app took the audio): the watchdog
                // retries within `restartEvery`.
                callbacks.log(.info, "audio interruption ended without shouldResume — watchdog retries shortly")
            }
        @unknown default:
            break
        }
    }

    /// Apple: after a media-services reset every audio object is invalid; the session must be
    /// configured again and new recorders created. The old segment has no index and is lost.
    private func handleMediaReset() {
        guard wantRecording else { return }
        callbacks.log(.warn, "media services were reset — rebuilding audio session and recorder")
        if gapStartedUp == nil { gapStartedUp = ProcessInfo.processInfo.systemUptime }
        finishCurrentSegment(event: "reset") // logs the segment end; the recorder object is invalid now
        failedRestarts = 0 // always log what happens with this restart
        attemptRestart("restarting audio after media services reset")
    }

    private func handleAppState(background: Bool) {
        appInBackground = background
        guard !background else { return }
        blockedInBackground = false // back to the normal restart cadence
        guard wantRecording, !(recorder?.isRecording ?? false) else { return }
        // In the foreground iOS lets us start the mic again: don't wait for the watchdog's throttle.
        attemptRestart("app is in the foreground — restarting audio")
    }

    private func handleRouteChange(_ n: Notification) {
        guard wantRecording else { return }
        let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "none"
        callbacks.log(.info, "audio route change (reason \(reason.map { String($0.rawValue) } ?? "?")) input=\(input)")
        pinBuiltInMic()
    }

    // MARK: AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let msg = error?.localizedDescription ?? "unknown"
        queue.async { self.callbacks.log(.error, "audio encode error: \(msg)") }
    }
}

/// When to rotate the segment file or restart a stopped recorder. Pure, unit-tested.
enum AudioSegmentPolicy {
    enum Action: Equatable { case none, rotate, restart }

    static let restartEvery: TimeInterval = AudioSegmentPolicyConstants.restartEvery
    /// Restart cadence once iOS refused the mic in the background: it rarely changes its mind before
    /// the app is opened (which retries at once), so don't hammer the session every 5 s.
    static let backgroundRetryEvery: TimeInterval = 60
    /// After a failed rotation the running segment continues; try again this much later.
    static let rotateRetryEvery: TimeInterval = 10

    static func decide(now: TimeInterval, isRecording: Bool, segmentStartedUp: TimeInterval, wantRecording: Bool,
                       interrupted: Bool, interruptedAtUp: TimeInterval, lastRestartAttemptUp: TimeInterval,
                       backgroundBlocked: Bool = false, lastRotateAttemptUp: TimeInterval = -.infinity) -> Action {
        if isRecording {
            guard now - segmentStartedUp >= AudioRecorderService.segmentDuration,
                  now - lastRotateAttemptUp >= rotateRetryEvery else { return .none }
            return .rotate
        }
        guard wantRecording else { return .none }
        // Mid-interruption (call/Siri) wait for "ended" — but not forever: iOS doesn't guarantee it.
        let interruptionBlocks = interrupted && now - interruptedAtUp < AudioRecorderService.interruptionRetryAfter
        let every = backgroundBlocked ? backgroundRetryEvery : restartEvery
        guard !interruptionBlocks, now - lastRestartAttemptUp > every else { return .none }
        return .restart
    }
}
