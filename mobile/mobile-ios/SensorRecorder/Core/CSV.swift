import Foundation

/// CSV formatting helpers. Always `.` decimal separator, no thousands separators, independent of
/// the phone's locale (a Romanian-locale phone would otherwise write `0,123`).
///
/// Numbers are formatted with integer arithmetic instead of `String(format:)`: at ~400 rows/s with
/// up to 18 values per row this keeps formatting cost negligible (thermal headroom matters on a
/// phone sitting in the sun on a dashboard).
enum CSV {
    /// 6 decimals: sensor values and `t_up`.
    static func f6(_ v: Double) -> String { fixed(v, decimals: 6) }
    /// 8 decimals: latitude / longitude.
    static func f8(_ v: Double) -> String { fixed(v, decimals: 8) }
    /// Integer Unix milliseconds.
    static func ms(_ utcMs: Double) -> String {
        guard utcMs.isFinite else { return "" }
        return String(Int64(utcMs.rounded()))
    }
    static func bool(_ b: Bool) -> String { b ? "1" : "0" }
    static func bool(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "" }

    private static let pow10: [Double] = [1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9]
    private static let pow10i: [Int64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000,
                                          10_000_000, 100_000_000, 1_000_000_000]

    /// Fixed-point formatting. NaN / ±inf become an empty field (pandas reads that as NaN).
    static func fixed(_ v: Double, decimals: Int) -> String {
        precondition((0...9).contains(decimals))
        guard v.isFinite else { return "" }
        let scaled = (v * pow10[decimals]).rounded()
        // Beyond ~9e18 integer conversion would trap; fall back to the slow path (never happens
        // for real sensor values but must not crash).
        guard abs(scaled) < 9.0e18 else { return String(format: "%.\(decimals)f", v) }
        var n = Int64(scaled)
        if decimals == 0 { return String(n) }
        let negative = n < 0
        if negative { n = -n }
        let div = pow10i[decimals]
        let intPart = n / div
        let frac = n % div
        var fracStr = String(frac)
        if fracStr.count < decimals {
            fracStr = String(repeating: "0", count: decimals - fracStr.count) + fracStr
        }
        // Avoid "-0.000000" for tiny negatives that round to zero.
        let sign = (negative && n != 0) ? "-" : ""
        return "\(sign)\(intPart).\(fracStr)"
    }

    /// RFC 4180 quoting for free-text fields.
    static func escape(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func row(_ fields: [String]) -> String { fields.joined(separator: ",") }
}
