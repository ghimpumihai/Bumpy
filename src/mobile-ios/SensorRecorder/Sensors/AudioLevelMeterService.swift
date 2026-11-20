import AVFoundation
import Foundation

/// Level meter only (S1) for sessions with audio recording OFF — e.g. buses and trams, where
/// recording other passengers' conversations is not allowed (spec §3.5, GDPR).
///
/// Samples flow from an `AVAudioEngine` input tap straight into RMS/peak arithmetic; no audio is
/// ever written anywhere. Emits `avg_dbfs` / `peak_dbfs` at ~10 Hz like the recorder does.
final class AudioLevelMeterService: AudioSource {
    private let queue = DispatchQueue(label: "sensorrecorder.audio-meter", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private var callbacks = AudioCallbacks()
    private var accumulator = LevelAccumulator(windowSeconds: 0.1)
    private let shared = Locked<(running: Bool, level: AudioLevelSample?)>((false, nil))
    private var observers: [NSObjectProtocol] = []
    private var wantRunning = false
    private var watchdog: DispatchSourceTimer?
    private var lastRestartUp: TimeInterval = 0
    /// Read on the tap thread: drop results after stop() (writers are closed right after).
    private let active = Locked(false)

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
            active.withLock { $0 = true }
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
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            shared.withLock { $0.running = false }
        }
    }

    private func startEngine() -> Bool {
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
                callbacks.log(.warn, "audio meter: no input available")
                return false
            }
            accumulator = LevelAccumulator(windowSeconds: 0.1)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            engine.prepare()
            try engine.start()
            installInterruptionObserver()
            shared.withLock { $0.running = true }
            callbacks.log(.info, "audio meter started (no audio recorded): \(Int(format.sampleRate)) Hz")
            return true
        } catch {
            callbacks.log(.warn, "audio meter failed to start: \(error.localizedDescription)")
            return false
        }
    }

    /// Runs on the tap's thread (serial, one buffer at a time). `accumulator` is confined to it
    /// (reset only in `startEngine`, before the tap is installed). The buffer is valid only during
    /// this call, so the cheap arithmetic (~1024 floats) is done inline and only results are handed on.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        let rate = buffer.format.sampleRate
        let windows = accumulator.add(samples: samples, sampleRate: rate, now: ProcessInfo.processInfo.systemUptime)
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
    /// "interruption ended" notification: retry every 5 s while it should be running.
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.wantRunning else { return }
            let running = self.engine.isRunning
            self.shared.withLock { $0.running = running }
            let now = ProcessInfo.processInfo.systemUptime
            if !running && now - self.lastRestartUp > 5 {
                self.lastRestartUp = now
                self.callbacks.log(.warn, "audio meter stopped — restarting")
                self.engine.inputNode.removeTap(onBus: 0)
                _ = self.startEngine()
            }
        }
        watchdog = t
        t.resume()
    }

    private func installInterruptionObserver() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Route/format change stopped the engine: the watchdog restarts it with the new format.
            self?.queue.async { self?.shared.withLock { $0.running = false } }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] n in
            guard let self,
                  let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.queue.async {
                if !self.engine.isRunning {
                    self.callbacks.log(.info, "audio meter: restarting after interruption")
                    try? self.engine.start()
                    self.shared.withLock { $0.running = self.engine.isRunning }
                }
            }
        })
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

    /// - Returns: zero or more completed windows; `t` of each is `now` (end of the buffer).
    mutating func add<C: Collection>(samples: C, sampleRate: Double, now: TimeInterval) -> [AudioLevelSample] where C.Element == Float {
        let perWindow = max(1, Int(sampleRate * windowSeconds))
        var out: [AudioLevelSample] = []
        for s in samples {
            let v = Double(s).isFinite ? Double(s) : 0 // a corrupt sample must not poison the window
            sumSquares += v * v
            peak = max(peak, abs(v))
            count += 1
            if count >= perWindow {
                let rms = (sumSquares / Double(count)).squareRoot()
                out.append(AudioLevelSample(t: now, avgDbfs: Self.dbfs(rms), peakDbfs: Self.dbfs(peak)))
                sumSquares = 0; peak = 0; count = 0
            }
        }
        return out
    }
}
