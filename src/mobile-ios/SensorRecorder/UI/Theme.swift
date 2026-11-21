import SwiftUI

/// High-contrast palette for use in a car in daylight (spec §7: big text, sunlight-readable).
enum Theme {
    static let ok = Color(red: 0.13, green: 0.80, blue: 0.35)
    static let warn = Color(red: 1.00, green: 0.70, blue: 0.00)
    static let problem = Color(red: 1.00, green: 0.23, blue: 0.19)
    static let neutral = Color(white: 0.55)
    static let panel = Color(white: 0.11)
    static let panelHigh = Color(white: 0.18)
    static let holdTrack = Color(white: 0.25)
    static let background = Color.black
    static let accent = Color(red: 0.25, green: 0.60, blue: 1.0)

    // Label buttons (distinct hues so they can be hit without reading)
    static let labelPothole = problem
    static let labelSpeedBump = Color(red: 1.00, green: 0.50, blue: 0.05)
    static let labelPhoneMoved = Color(red: 0.62, green: 0.32, blue: 0.95)

    /// Map track colors by speed bucket: < 10, < 30, < 50, < 80, ≥ 80 km/h.
    static let speedBuckets: [Color] = [accent, ok, Color(red: 1.0, green: 0.88, blue: 0.10), labelSpeedBump, problem]

    // Foregrounds on coloured surfaces, overlays
    /// Text on bright surfaces: ok/warn/accent/speed-bump (white there fails WCAG contrast).
    static let onBright = Color.black
    /// Text on dark surfaces and on `problem`/`labelPhoneMoved` (bold/large text only).
    static let onSurface = Color.white
    static let toastBackground = Color.white
    static let toastForeground = Color.black
    static let hairline = Color.white.opacity(0.08)
    static let plotBackground = Color.white.opacity(0.03)
    static let plotZeroLine = Color.white.opacity(0.2)
    static let mapLabelBackground = Color.black.opacity(0.6)

    static func color(_ level: HealthLevel) -> Color {
        switch level {
        case .ok: return ok
        case .warn: return warn
        case .problem: return problem
        }
    }

    static let mono = Font.system(.body, design: .monospaced)
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 12
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }
}
