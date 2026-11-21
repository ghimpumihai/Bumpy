import AVFoundation
import Foundation
import UIKit

/// Level meter only (S1) for sessions with audio recording OFF — e.g. buses and trams, where
/// recording other passengers' conversations is not allowed (spec §3.5, GDPR).
///
/// Samples flow from an `AVAudioEngine` input tap straight into RMS/peak arithmetic; no audio is
/// ever written anywhere. Emits `avg_dbfs` / `peak_dbfs` at ~10 Hz like the recorder does, stamped
/// with the capture time of the samples (the tap's `AVAudioTime`), not with the processing time.
final class AudioLevelMeterService: AudioSource {
    private let queue = DispatchQueue(label: "sensorrecorder.audio-meter", qos: .userInitiated)
    /// Confined to `queue`. Replaced after a media-services reset: Apple requires a new engine then
    /// (the old one and its nodes are invalid; restarting it never works).
    private var engine = AVAudioEngine()
    private var callbacks = AudioCallbacks()
    private var accumulator = LevelAccumulator(windowSeconds: 0.1)
    private let shared = Locked<(running: Bool, level: AudioLevelSample?)>((false, nil))
    /// Session/app observers, installed once per start(); `engineObserver` follows `engine`.
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    private var wantRunning = false
    private var watchdog: DispatchSourceTimer?
    private var lastRestartUp: TimeInterval = 0
    /// Failed starts since the meter last ran: only the first of a streak is logged.
    private var failedStarts = 0
    /// Read on the tap thread: drop results after stop() (writers are closed right after).
    private let active = Locked(false)

    static let restartEvery: TimeInterval = AudioSegmentPolicyConstants.restartEvery

    let formatDescription = "level meter only (audio recording OFF)"
    /// Never writes audio files.
    var bytesWritten: Int64 { 0 }
    var latestLevel: AudioLevelSample? { shared.current.level }
    /// "Recording" in the AudioSource sense = the meter is running.
    var isRecording: Bool { shared.current.running }
    var recordsAudio: Bool { false }

    @discardableResult
    func start(folder: URL, _ callbacks: AudioCallbacks) -> Bool {
        queue.sync {
            self.callbacks = callbacks
            wantRunning = true
            failedStarts = 0
            active.withLock { $0 = true }
            installObservers()
            startWatchdog() // also retries if the first start fails
            return startEngine()
        }
    }

    func stop() {
        queue.sync {
            wantRunning = false
            active.withLock { $0 = false }
            watchdog?.cancel()
            watchdog = nil
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
            engineObserver = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            shared.withLock { $0.running = false }
        }
    }

    /// (Re)configures and activates the session, (re)installs the tap and starts the engine.
    /// Every restart path goes through here, so `setActive(true)` is never skipped.
    private func startEngine() -> Bool {
        lastRestartUp = ProcessInfo.processInfo.systemUptime
        do {
            let session = AVAudioSession.sharedInstance()
            try AudioRecorderService.configure(session)
            try session.setActive(true)
            if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(mic)
            }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                startFailed("audio meter: no input available")
                return false
            }
            accumulator = LevelAccumulator(windowSeconds: 0.1)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
                self?.process(buffer, at: when)
            }
            engine.prepare()
            try engine.start()
            observeEngineConfiguration()
            shared.withLock { $0.running = true }
            let streak = failedStarts > 0 ? " after \(failedStarts) failed attempt(s)" : ""
            failedStarts = 0
            callbacks.log(.info, "audio meter started (no audio recorded): \(Int(format.sampleRate)) Hz\(streak)")
            return true
        } catch {
            startFailed("audio meter failed to start: \(AudioRecorderService.describe(error))")
            return false
        }
    }

    private func startFailed(_ message: String) {
        if failedStarts == 0 { callbacks.log(.warn, message) }
        failedStarts += 1
        shared.withLock { $0.running = false }
    }

    private func restart(_ reason: String) {
        if failedStarts == 0 { callbacks.log(.warn, reason) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = startEngine()
    }

    /// Runs on the tap's thread (serial, one buffer at a time). `accumulator` is confined to it
    /// (reset only in `startEngine`, before the tap is installed). The buffer is valid only during
    /// this call, so the cheap arithmetic (~1024 floats) is done inline and only results are handed on.
    private func process(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        let rate = buffer.format.sampleRate
        let nowUp = ProcessInfo.processInfo.systemUptime
        let startUp = CaptureClock.bufferStartUp(
            bufferHostSec: when.isHostTimeValid && when.hostTime != 0 ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil,
            nowHostSec: AVAudioTime.seconds(forHostTime: mach_absolute_time()),
            nowUp: nowUp, bufferDuration: rate > 0 ? Double(buffer.frameLength) / rate : 0)
        let windows = accumulator.add(samples: samples, sampleRate: rate, startUp: startUp)
        guard !windows.isEmpty, active.current else { return }
        queue.async { [weak self] in
            guard let self, self.wantRunning else { return }
            for w in windows {
                self.shared.withLock { $0.level = w }
                self.callbacks.level(w)
            }
        }
    }

    /// The engine can stop on calls, route changes or media resets, and iOS does not guarantee an
    /// "interruption ended" notification: retry every `restartEvery` while it should be running.
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.wantRunning else { return }
            let running = self.engine.isRunning
            self.shared.withLock { $0.running = running }
            if !running && ProcessInfo.processInfo.systemUptime - self.lastRestartUp > Self.restartEvery {
                self.restart("audio meter stopped — restarting")
            }
        }
        watchdog = t
        t.resume()
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            self?.queue.async {
                guard let self, self.wantRunning, !self.engine.isRunning else { return }
                if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                    self.restart("audio meter: restarting after interruption")
                } else {
                    self.callbacks.log(.info, "audio meter: interruption ended without shouldResume — watchdog retries shortly")
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.rebuildEngine() }
        })
        // In the foreground iOS lets the mic start again: don't wait for the watchdog.
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async {
                    guard let self, self.wantRunning, !self.engine.isRunning else { return }
                    self.restart("audio meter: app is in the foreground — restarting")
                }
            })
        }
    }

    /// Route/format change stopped the engine: the watchdog restarts it with the new format.
    private func observeEngineConfiguration() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.shared.withLock { $0.running = false } }
        }
    }

    private func rebuildEngine() {
        guard wantRunning else { return }
        callbacks.log(.warn, "audio meter: media services were reset — rebuilding the audio engine")
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine = AVAudioEngine() // the old engine is invalid; never touch its nodes again
        failedStarts = 0
        _ = startEngine()
    }
}

/// Maps the tap's capture time (host clock) onto the app's uptime base (`TimeBase`). Pure, tested.
enum CaptureClock {
    /// Host times older than this (or in the future) are treated as invalid.
    static let maxBufferAge: TimeInterval = 2

    /// - Parameters:
    ///   - bufferHostSec: host time of the buffer's first frame in seconds, nil if invalid.
    ///   - nowHostSec / nowUp: host clock and uptime read back-to-back now.
    ///   - bufferDuration: frames / sample rate.
    /// - Returns: uptime of the first frame. Converted through the buffer's *age* so the two clocks'
    ///   epochs never have to match; without a valid host time, assumes the buffer ended just now.
    static func bufferStartUp(bufferHostSec: Double?, nowHostSec: Double, nowUp: TimeInterval,
                              bufferDuration: TimeInterval) -> TimeInterval {
        let fallback = nowUp - bufferDuration
        guard let bufferHostSec else { return fallback }
        let age = nowHostSec - bufferHostSec
        guard age.isFinite, age >= 0, age <= maxBufferAge else { return fallback }
        return nowUp - age
    }
}

/// Accumulates audio samples into fixed time windows and returns RMS / peak in dBFS per window.
/// Pure value type (unit-tested).
struct LevelAccumulator {
    let windowSeconds: Double
    private var sumSquares = 0.0
    private var peak = 0.0
    private var count = 0

    init(windowSeconds: Double) { self.windowSeconds = windowSeconds }

    /// Always finite (max(NaN, x) is NaN in Swift, so check explicitly): floor −140 dBFS.
    static func dbfs(_ linear: Double) -> Double {
        guard linear.isFinite, linear > 1e-7 else { return -140 }
        return 20 * log10(linear)
    }

    /// - Parameter startUp: capture uptime of the first sample in `samples`.
    /// - Returns: zero or more completed windows; `t` of each is the capture time of the end of its
    ///   last sample (a window can start in an earlier buffer and end in this one).
    mutating func add<C: Collection>(samples: C, sampleRate: Double, startUp: TimeInterval) -> [AudioLevelSample] where C.Element == Float {
        let perWindow = max(1, Int(sampleRate * windowSeconds))
        let rate = sampleRate > 0 ? sampleRate : 1
        var out: [AudioLevelSample] = []
        for (i, s) in samples.enumerated() {
            let v = Double(s).isFinite ? Double(s) : 0 // a corrupt sample must not poison the window
            sumSquares += v * v
            peak = max(peak, abs(v))
            count += 1
            if count >= perWindow {
                let rms = (sumSquares / Double(count)).squareRoot()
                let t = startUp + Double(i + 1) / rate
                out.append(AudioLevelSample(t: t, avgDbfs: Self.dbfs(rms), peakDbfs: Self.dbfs(peak)))
                sumSquares = 0; peak = 0; count = 0
            }
        }
        return out
    }
}
