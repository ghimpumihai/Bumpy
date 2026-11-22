import Foundation

/// Second-order IIR section (direct form II transposed).
struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Bilinear transform of H(s) = (n2 s² + n1 s + n0) / (d2 s² + d1 s + d0) at sample rate `fs`.
    init(analogNum n: (Double, Double, Double), den d: (Double, Double, Double), fs: Double) {
        let k = 2 * fs
        let k2 = k * k
        let (n2, n1, n0) = n
        let (d2, d1, d0) = d
        let a0 = d2 * k2 + d1 * k + d0
        self.init(b0: (n2 * k2 + n1 * k + n0) / a0,
                  b1: (2 * n0 - 2 * n2 * k2) / a0,
                  b2: (n2 * k2 - n1 * k + n0) / a0,
                  a1: (2 * d0 - 2 * d2 * k2) / a0,
                  a2: (d2 * k2 - d1 * k + d0) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// |H(e^{jω})| at frequency f.
    func magnitude(at f: Double, fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let (c1, s1, c2, s2) = (cos(w), -sin(w), cos(2 * w), -sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
        let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
        return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
    }
}

/// ISO 2631-1:1997 frequency weighting **Wf** (motion sickness, vertical), as a cascade of four
/// biquads: band-limiting high-pass (0.08 Hz) and low-pass (0.63 Hz), acceleration–velocity
/// transition (f4 = 0.25 Hz, Q4 = 0.86) and upward step (f5 = 0.0625 Hz, Q5 = 0.80, f6 = 0.1 Hz, Q6 = 0.80).
/// On-device use is a *live estimate only*; the real processing happens in the cloud.
struct WfFilter {
    private var sections: [Biquad]
    let fs: Double

    init(fs: Double) {
        self.fs = fs
        let q1 = 1 / 2.0.squareRoot()
        let w1 = 2 * Double.pi * 0.08, w2 = 2 * Double.pi * 0.63
        let w4 = 2 * Double.pi * 0.25, q4 = 0.86
        let w5 = 2 * Double.pi * 0.0625, q5 = 0.80
        let w6 = 2 * Double.pi * 0.1, q6 = 0.80
        sections = [
            Biquad(analogNum: (1, 0, 0), den: (1, w1 / q1, w1 * w1), fs: fs),                 // high-pass
            Biquad(analogNum: (0, 0, w2 * w2), den: (1, w2 / q1, w2 * w2), fs: fs),           // low-pass
            Biquad(analogNum: (0, 0, 1), den: (1 / (w4 * w4), 1 / (q4 * w4), 1), fs: fs),      // a-v transition (f3 = ∞)
            Biquad(analogNum: (1, w5 / q5, w5 * w5), den: (1, w6 / q6, w6 * w6), fs: fs),     // upward step
        ]
    }

    mutating func process(_ x: Double) -> Double {
        var y = x
        for i in sections.indices { y = sections[i].process(y) }
        return y
    }

    func magnitude(at f: Double) -> Double {
        sections.reduce(1) { $0 * $1.magnitude(at: f, fs: fs) }
    }
}

/// The backend's road-roughness band (services/processor/roadride/dsp.py `SOS_BAND`): 4th-order
/// Butterworth band-pass 1–30 Hz at 100 Hz, coefficients from
/// `scipy.signal.butter(4, (1, 30), "bandpass", fs=100, output="sos")`, so the phone's "roughness
/// now" is the same number the web dashboard shows.
struct RoughnessBand {
    static let fs = 100.0
    private var sections = [
        Biquad(b0: 0.15008712507227703, b1: 0.30017425014455407, b2: 0.15008712507227703,
               a1: 0.28947536353801495, a2: 0.06256363300540586),
        Biquad(b0: 1, b1: 2, b2: 1, a1: 0.4493070470669376, a2: 0.4809961054440336),
        Biquad(b0: 1, b1: -2, b2: 1, a1: -1.8829072394807296, a2: 0.8869402293234886),
        Biquad(b0: 1, b1: -2, b2: 1, a1: -1.9506769966911766, a2: 0.9545821370290172),
    ]

    mutating func process(_ x: Double) -> Double {
        var y = x
        for i in sections.indices { y = sections[i].process(y) }
        return y
    }

    func magnitude(at f: Double) -> Double {
        sections.reduce(1) { $0 * $1.magnitude(at: f, fs: Self.fs) }
    }
}

/// Live-plot ring buffers and simple on-device estimates (spec §7 dashboard). Fed from the motion
/// queue at 100 Hz; read by the UI at ~8 Hz.
final class LiveSignals: @unchecked Sendable {
    static let verticalSeconds = 10.0
    static let lateralSeconds = 60.0
    static let decimatedHz = 10.0
    static let g = 9.80665
    static let roughnessTauS = 5.0  // backend dsp.ROUGHNESS_TAU_S

    private struct State {
        var vertical = RingBuffer<Double>(capacity: 1000)    // 10 s @ 100 Hz, g
        var lateral = RingBuffer<Double>(capacity: 600)      // 60 s @ 10 Hz, g (low-passed)
        var lateralLP = 0.0
        var lastT: Double?
        var decimAccum = 0.0
        var decimCount = 0
        var decimNextT: Double?  // end of the current 0.1 s block, on a grid from the first sample
        var wf = WfFilter(fs: LiveSignals.decimatedHz)
        var msdvIntegral = 0.0 // ∫ a_w² dt  (m²/s³)
        var band = RoughnessBand()
        var roughEMA: Double?  // exponential mean of the band-passed vertical², (m/s²)²
    }
    private let state = Locked(State())

    /// The phone's acceleration in g: vertical positive up, lateral positive to the vehicle's left
    /// (the backend's convention, dsp.py `_axes`). CoreMotion's userAcceleration is minus the phone's
    /// acceleration: screen up it reads 0 at rest and +1 g on z in free fall (total 0 − gravity −1 g).
    /// Lateral assumes the device +x axis points to the vehicle's right, as in both mounts of the
    /// protocol (flat with the top to the front, or upright facing the driver).
    static func project(_ s: DeviceMotionSample) -> (vertical: Double, lateral: Double) {
        let down = s.gravity.normalized
        let a = s.userAccel * -1
        let vertical = -a.dot(down)
        let xAxis = Vec3(x: 1, y: 0, z: 0)
        let rightH = (xAxis - down * xAxis.dot(down)).normalized
        return (vertical, -a.dot(rightH))
    }

    func add(_ s: DeviceMotionSample) {
        let (v, lat) = Self.project(s)
        state.withLock { st in
            st.vertical.append(v)
            // 1 Hz single-pole low-pass for the sway plot
            let dt = st.lastT.map { max(0.001, min(0.1, s.t - $0)) } ?? 0.01
            st.lastT = s.t
            let rc = 1 / (2 * Double.pi * 1.0)
            let alpha = dt / (rc + dt)
            st.lateralLP += alpha * (lat - st.lateralLP)
            let b = st.band.process(v * Self.g)
            st.roughEMA = st.roughEMA.map { $0 + dt / Self.roughnessTauS * (b * b - $0) } ?? b * b
            // Decimate to 10 Hz (block mean) for the lateral plot and the Wf filter. Blocks sit on a
            // fixed 0.1 s grid: Wf is designed for exactly 10 Hz and each block adds 0.1 s of dose,
            // so a block that starts at the previous block's last sample (11 samples whenever the
            // timestamps jitter) would stretch time and read the dose ~6 % low.
            let period = 1 / Self.decimatedHz
            if st.decimNextT == nil { st.decimNextT = s.t + period }
            if let next = st.decimNextT, s.t >= next, st.decimCount > 0 {
                let mean = st.decimAccum / Double(st.decimCount)
                let aw = st.wf.process(mean * Self.g)
                st.msdvIntegral += aw * aw * period
                st.lateral.append(st.lateralLP)
                st.decimAccum = 0
                st.decimCount = 0
                // After a stall longer than a block, restart the grid here instead of emitting empty blocks.
                st.decimNextT = s.t < next + period ? next + period : s.t + period
            }
            st.decimAccum += v
            st.decimCount += 1
        }
    }

    struct Snapshot {
        var vertical: [Double]
        var lateral: [Double]
        /// Road roughness now, m/s²: RMS of the 1–30 Hz band-passed vertical acceleration, averaged
        /// exponentially over ~5 s. The backend's `roughnessNow`, which the web dashboard shows.
        var roughnessRms: Double
        /// Motion sickness dose value so far (vertical, Wf), m/s^1.5.
        var msdv: Double
    }

    func snapshot() -> Snapshot {
        state.withLock { st in
            Snapshot(vertical: st.vertical.elements, lateral: st.lateral.elements,
                     roughnessRms: (st.roughEMA ?? 0).squareRoot(), msdv: st.msdvIntegral.squareRoot())
        }
    }
}

/// GPS track for the mini map, thinned to points ≥ 5 m apart.
final class TrackBuffer: @unchecked Sendable {
    struct Point: Equatable, Sendable { var lat: Double; var lon: Double; var speed: Double }
    private let points = Locked<[Point]>([])
    private let version = Locked(0)
    static let minSpacingM = 5.0
    static let maxPoints = 20_000

    func add(_ s: LocationSample) {
        guard s.hAcc >= 0, s.hAcc <= 50 else { return } // discard junk fixes from the display
        let p = Point(lat: s.lat, lon: s.lon, speed: max(0, s.speed))
        points.withLock { pts in
            if let last = pts.last, Self.distanceM(last, p) < Self.minSpacingM { return }
            pts.append(p)
            if pts.count > Self.maxPoints { pts.removeFirst(pts.count - Self.maxPoints) }
            version.withLock { $0 += 1 }
        }
    }

    var current: (version: Int, points: [Point]) { points.withLock { pts in (version.current, pts) } }

    static func distanceM(_ a: Point, _ b: Point) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let x = dLon * cos((a.lat + b.lat) / 2 * .pi / 180)
        return (x * x + dLat * dLat).squareRoot() * r
    }
}
