import AVFoundation
import Foundation

/// Audio recording (S2) + 10 Hz level meter (S1).
///
/// Design notes
/// - Session: `.playAndRecord` + mode `.measurement` (no AGC / voice processing, spec §3.5). We use
///   playAndRecord instead of `.record` only so the alert/sickness-prompt sounds can still play.
/// - Input is pinned to the built-in mic so a car Bluetooth hands-free system can't hijack it.
/// - Files are written as **segments** (`audio_000.m4a`, `audio_001.m4a`, …) of 5 minutes. An
///   AAC/MP4 file is only playable once `stop()` writes its index, so a crash or kill would
///   otherwise destroy the whole drive's audio. With segments we lose at most the current one.
///   Rotation starts the next recorder before stopping the previous one (overlap, no gap).
///   Each segment start is logged with its uptime (`clock.csv source=audio_start`, and
///   `audio_segments.csv`), so every file maps linearly onto the sensor clock.
/// - After an interruption (phone call, Siri) a *new* segment is started rather than resuming
///   the old file, which keeps that mapping exact.
final class AudioRecorderService: NSObject, AudioSource, AVAudioRecorderDelegate {
    static let segmentDuration: TimeInterval = 300
    static let meterInterval: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "sensorrecorder.audio", qos: .userInitiated)
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
        queue.sync {
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
            self.meterTicks = 0
            self.shared.withLock { $0 = (false, nil, 0) }
            installObservers()
            // The meter timer is also the watchdog: start it even if the first attempt fails.
            startMeterTimer()
            guard configureSession() else { return false }
            return startNewSegment()
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

    // MARK: - Session

    private func configureSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try Self.configure(session)
            try session.setActive(true)
            pinBuiltInMic()
            return true
        } catch {
            callbacks.log(.error, "audio session setup failed: \(error.localizedDescription)")
            return false
        }
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
    ///   without this the sickness prompt and PROBLEM alerts would be silent and vibration-free.
    static func configure(_ session: AVAudioSession) throws {
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setPreferredSampleRate(48_000)
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    // MARK: - Segments

    @discardableResult
    private func startNewSegment() -> Bool {
        guard let folder else { return false }
        let index = segmentIndex + 1
        let file = SessionFileName.audioSegment(index)
        let url = folder.appendingPathComponent(file)
        do {
            let r = try AVAudioRecorder(url: url, settings: Self.settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.prepareToRecord() else {
                callbacks.log(.error, "audio prepareToRecord failed for \(file)")
                return false
            }
            var ok = r.record()
            var t = ProcessInfo.processInfo.systemUptime // uptime when record() returned (spec §5)
            if !ok, recorder != nil {
                // Some routes refuse a second simultaneous recorder: stop the old one, then retry.
                finishCurrentSegment(event: "stop")
                ok = r.record()
                t = ProcessInfo.processInfo.systemUptime
            }
            guard ok else {
                callbacks.log(.error, "audio record() returned false for \(file)")
                try? FileManager.default.removeItem(at: url)
                return false
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
            shared.withLock { $0.recording = true }
            return true
        } catch {
            callbacks.log(.error, "audio recorder creation failed: \(error.localizedDescription)")
            return false
        }
    }

    private func finishCurrentSegment(event: String) {
        guard let r = recorder, let file = currentFile else { return }
        r.stop()
        callbacks.segmentEvent(ProcessInfo.processInfo.systemUptime, event, file)
        recorder = nil
        currentFile = nil
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
            interrupted: interrupted, interruptedAtUp: interruptedAtUp, lastRestartAttemptUp: lastRestartAttemptUp)
        if let r = recorder, isRec {
            r.updateMeters()
            let s = AudioLevelSample(t: now, avgDbfs: Double(r.averagePower(forChannel: 0)),
                                     peakDbfs: Double(r.peakPower(forChannel: 0)))
            shared.withLock { $0.level = s; $0.recording = true }
            callbacks.level(s)
            if action == .rotate {
                startNewSegment()
            }
        } else {
            shared.withLock { $0.recording = false }
            if action == .restart {
                interrupted = false
                lastRestartAttemptUp = now
                callbacks.log(.warn, "audio not recording — attempting restart")
                finishCurrentSegment(event: "stop")
                if configureSession() { startNewSegment() }
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

    // MARK: - Interruptions & route changes

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
    }

    private func handleInterruption(_ n: Notification) {
        guard wantRecording,
              let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interrupted = true
            interruptedAtUp = ProcessInfo.processInfo.systemUptime
            callbacks.log(.warn, "audio interrupted (call/Siri/other app)")
            finishCurrentSegment(event: "interrupted")
            shared.withLock { $0.recording = false }
        case .ended:
            interrupted = false
            callbacks.log(.info, "audio interruption ended — starting new segment")
            if configureSession() { startNewSegment() }
        @unknown default:
            break
        }
    }

    private func handleMediaReset() {
        guard wantRecording else { return }
        callbacks.log(.warn, "media services were reset — rebuilding audio session")
        finishCurrentSegment(event: "reset") // logs the segment end; recorder object is invalid now
        if configureSession() { startNewSegment() }
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

    static let restartEvery: TimeInterval = 5

    static func decide(now: TimeInterval, isRecording: Bool, segmentStartedUp: TimeInterval, wantRecording: Bool,
                       interrupted: Bool, interruptedAtUp: TimeInterval, lastRestartAttemptUp: TimeInterval) -> Action {
        if isRecording {
            return now - segmentStartedUp >= AudioRecorderService.segmentDuration ? .rotate : .none
        }
        guard wantRecording else { return .none }
        // Mid-interruption (call/Siri) wait for "ended" — but not forever: iOS doesn't guarantee it.
        let interruptionBlocks = interrupted && now - interruptedAtUp < AudioRecorderService.interruptionRetryAfter
        guard !interruptionBlocks, now - lastRestartAttemptUp > restartEvery else { return .none }
        return .restart
    }
}
