import Foundation
import XCTest
@testable import SensorRecorder

final class FakeClock: ClockSource, @unchecked Sendable {
    private let state: Locked<(up: Double, utcMs: Double)>
    init(up: Double = 1000, utcMs: Double = 1_763_716_323_512) { state = Locked((up, utcMs)) }
    func uptime() -> TimeInterval { state.current.up }
    func nowUtcMs() -> Double { state.current.utcMs }
    func advance(_ s: Double) { state.withLock { $0.up += s; $0.utcMs += s * 1000 } }
    /// Simulate an NTP correction of the wall clock only.
    func jumpWall(_ ms: Double) { state.withLock { $0.utcMs += ms } }
}

func makeTempDir(_ name: String = #function) throws -> URL {
    let safe = name.replacingOccurrences(of: "()", with: "")
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SRTests-\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func readCSV(_ url: URL) throws -> (header: [String], rows: [[String]]) {
    let text = try String(contentsOf: url, encoding: .utf8)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    guard let h = lines.first else { return ([], []) }
    return (h.components(separatedBy: ","), lines.dropFirst().map { $0.components(separatedBy: ",") })
}

final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let state = Locked<(responses: [Result<Int, Error>], requests: [URLRequest])>(([], []))
    var defaultStatus = 200

    func enqueue(_ statuses: Int...) { state.withLock { $0.responses += statuses.map { .success($0) } } }
    func enqueueError(_ e: Error) { state.withLock { $0.responses.append(.failure(e)) } }
    var requests: [URLRequest] { state.current.requests }

    func send(_ request: URLRequest) async throws -> Int {
        let r: Result<Int, Error> = state.withLock { s in
            s.requests.append(request)
            return s.responses.isEmpty ? .success(defaultStatus) : s.responses.removeFirst()
        }
        return try r.get()
    }
}

final class FakeDeviceStatus: DeviceStatusSource {
    var status = DeviceStatus(batteryLevel: 0.8, batteryState: "charging", thermal: .nominal, lowPowerMode: false,
                              freeDiskBytes: 50_000_000_000, networkStatus: "satisfied", networkType: "wifi")
    func currentStatus() -> DeviceStatus { status }
}

/// Emits GPS fixes at 1 Hz on a background queue.
final class FakeLocationSource: LocationSource {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fake-location")
    var started = false

    func startRecording(_ callbacks: LocationCallbacks) {
        started = true
        var i = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler {
            i += 1
            let s = LocationSample(utcMs: Date().timeIntervalSince1970 * 1000, lat: 46.77121 + Double(i) * 0.0001,
                                   lon: 23.62363, alt: 352.1, ellAlt: 390.0, hAcc: 4.7, vAcc: 3.0, speed: 8.4,
                                   speedAcc: 0.5, course: 92, courseAcc: 5, isSimulated: false)
            callbacks.location(s)
            callbacks.heading(HeadingSample(utcMs: s.utcMs, magneticHeading: 90, trueHeading: 95, accuracy: 10,
                                            raw: Vec3(x: 1, y: 2, z: 3)))
        }
        timer = t
        t.resume()
    }

    func stopRecording() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }
}

final class FakeAltimeter: AltimeterSource {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fake-alt")
    var isRelativeAvailable: Bool { true }
    var isAbsoluteAvailable: Bool { true }
    func start(_ cb: AltimeterCallbacks) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler {
            let up = ProcessInfo.processInfo.systemUptime
            cb.relative(AltimeterSample(t: up, relativeAltitudeM: 0.5, pressureKPa: 97.1))
            cb.absolute(AbsoluteAltitudeSample(t: up, altitudeM: 350, accuracyM: 5, precisionM: 0.5))
        }
        timer = t
        t.resume()
    }
    func stop() { timer?.cancel(); timer = nil; queue.sync {} }
}

final class FakeActivity: ActivitySource {
    var isAvailable: Bool { true }
    func start(_ handler: @escaping (ActivitySample) -> Void) {
        handler(ActivitySample(t: ProcessInfo.processInfo.systemUptime, stationary: false, walking: false, running: false,
                               automotive: true, cycling: false, unknown: false, confidence: 2,
                               startUtcMs: Date().timeIntervalSince1970 * 1000))
    }
    func stop() {}
}

/// Audio fake: emits 10 Hz levels, reports a segment start, writes a dummy file.
final class FakeAudio: AudioSource {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fake-audio")
    private let rec = Locked(false)
    var failToStart = false
    /// Number of audio segments to simulate (rotation): each gets a file, start and stop events.
    var segments = 1
    var isRecording: Bool { rec.current }
    var bytesWritten: Int64 { 1234 }
    var latestLevel: AudioLevelSample? { nil }
    var formatDescription: String { "fake" }
    var recordsAudio = true

    func start(folder: URL, _ cb: AudioCallbacks) -> Bool {
        guard !failToStart else { return false }
        for i in 0..<segments {
            let name = SessionFileName.audioSegment(i)
            try? Data(repeating: 0, count: 1234).write(to: folder.appendingPathComponent(name))
            if i > 0 { cb.segmentEvent(ProcessInfo.processInfo.systemUptime, "stop", SessionFileName.audioSegment(i - 1)) }
            cb.segmentEvent(ProcessInfo.processInfo.systemUptime, "start", name)
        }
        lastSegment = SessionFileName.audioSegment(segments - 1)
        segmentCallback = cb.segmentEvent
        rec.withLock { $0 = true }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.1)
        t.setEventHandler { cb.level(AudioLevelSample(t: ProcessInfo.processInfo.systemUptime, avgDbfs: -31, peakDbfs: -12)) }
        timer = t
        t.resume()
        return true
    }

    private var lastSegment: String?
    private var segmentCallback: ((TimeInterval, String, String) -> Void)?

    func stop() {
        timer?.cancel(); timer = nil; queue.sync {}
        if let last = lastSegment { segmentCallback?(ProcessInfo.processInfo.systemUptime, "stop", last) }
        lastSegment = nil
        rec.withLock { $0 = false }
    }
}

/// Deterministic RNG (SplitMix64) so randomized tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
