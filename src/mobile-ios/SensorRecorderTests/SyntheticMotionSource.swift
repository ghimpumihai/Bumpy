import Foundation
@testable import SensorRecorder

/// TEST-ONLY synthetic 100 Hz motion source (the app ships real CoreMotion only).
/// Produces a plausible car ride: gravity on -z (phone flat, screen up), slow lateral sway
/// (~0.2 Hz, the motion-sickness band), road vibration, and a pothole spike every ~7 s.
/// Sessions recorded with it are flagged `syntheticSensors: true` in session.json.
final class SyntheticMotionSource: MotionSource {
    private let queue = DispatchQueue(label: "sensorrecorder.synthetic-motion", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var tick: Int = 0
    private let rateHz: Double
    private let uptime: () -> TimeInterval
    private var rng = SystemRandomNumberGenerator()

    var isSynthetic: Bool { true }

    init(rateHz: Double = 100, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.rateHz = rateHz
        self.uptime = uptime
    }

    var availability: MotionAvailability { MotionAvailability(deviceMotion: true, accel: true, gyro: true, mag: true) }

    func start(_ cb: MotionCallbacks) {
        stop()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / rateHz
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.emit(cb) }
        timer = t
        t.resume()
    }

    private func noise(_ amp: Double) -> Double { Double.random(in: -amp...amp, using: &rng) }

    private func emit(_ cb: MotionCallbacks) {
        let now = uptime()
        tick += 1
        let sway = 0.08 * sin(2 * .pi * 0.2 * now)               // lateral, g
        let surge = 0.04 * sin(2 * .pi * 0.07 * now)             // longitudinal, g
        let phase = now.truncatingRemainder(dividingBy: 7)
        let bump = phase < 0.08 ? 0.6 * sin(.pi * phase / 0.08) : 0 // pothole every 7 s
        let vib = noise(0.015) + bump
        let ua = Vec3(x: sway + noise(0.005), y: surge + noise(0.005), z: vib)
        let g = Vec3(x: 0, y: 0, z: -1)
        let rr = Vec3(x: noise(0.01) + bump * 0.5, y: noise(0.01), z: 0.05 * sin(2 * .pi * 0.2 * now))
        cb.deviceMotion(DeviceMotionSample(t: now, userAccel: ua, gravity: g, rotationRate: rr,
                                           quaternion: Quaternion(w: 1, x: 0, y: 0, z: 0),
                                           roll: 0.01 * sway, pitch: 0.01 * surge, yaw: 0))
        cb.accel(Vec3Sample(t: now, v: ua + g + Vec3(x: noise(0.002), y: noise(0.002), z: noise(0.002))))
        cb.gyro(Vec3Sample(t: now, v: rr + Vec3(x: 0.002, y: -0.001, z: 0.001)))
        if tick % 2 == 0 {
            cb.mag(Vec3Sample(t: now, v: Vec3(x: 20 + noise(0.5), y: -5 + noise(0.5), z: -40 + noise(0.5))))
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }
}
