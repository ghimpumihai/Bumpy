import SwiftUI
import UIKit

/// Neutral palette shared with the web dashboard (light only), ink-black accent. Colour appears
/// only when something is wrong: amber WARN, red PROBLEM; OK is plain text.
enum Theme {
    static let background = Color.white
    static let surface = Color(hex: 0xF5F5F5)
    static let text = Color(hex: 0x0A0A0A)
    static let muted = Color(hex: 0x737373)
    static let line = Color(hex: 0xE5E5E5)
    /// Primary buttons, the recording dot, progress bars.
    static let ink = Color(hex: 0x0A0A0A)
    static let onInk = Color.white
    static let warn = Color(hex: 0xB45309)
    static let problem = Color(hex: 0xB91C1C)
    static let scrim = Color(hex: 0x0A0A0A).opacity(0.35)

    static func color(_ level: HealthLevel) -> Color {
        switch level {
        case .ok: return muted
        case .warn: return warn
        case .problem: return problem
        }
    }

    static let gutter: CGFloat = 16

    /// Geist, the web dashboard's typeface (variable font in `Resources/Fonts`, SIL OFL). Fixed sizes
    /// like the design: the layout is built for one glance in a moving car, not for Dynamic Type.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        // `.weight()` doesn't move a custom variable font's `wght` axis, so set the axis itself.
        let wght: Int
        switch weight {
        case .medium: wght = 500
        case .semibold: wght = 600
        case .bold: wght = 700
        default: wght = 400
        }
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: "Geist",
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: wght],
        ])
        return Font(UIFont(descriptor: descriptor, size: size))
    }

    /// The OpenType tag 'wght' as a number (CoreText variation key).
    private static let wghtAxis = 0x7767_6874
}

/// A multi-line headline with tight leading (design: line-height 1.05). SwiftUI can't set a line
/// height below the font's own, so each line is its own Text, one `size × lineHeight` apart.
struct Headline: View {
    let lines: [String]
    var size: CGFloat = 40
    var lineHeight: CGFloat = 1.05

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).frame(height: size * lineHeight, alignment: .leading)
            }
        }
        .font(Theme.font(size, .semibold))
        .tracking(-size * 0.03) // letter-spacing −1.2 px at 40
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.joined(separator: " "))
        .accessibilityAddTraits(.isHeader)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The black 56 pt button used for the one main action on each screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(17, .semibold))
            .foregroundStyle(Theme.onInk)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 44 pt round outline button (menu, close, back).
struct CircleIconButton: View {
    let systemName: String
    let label: String
    let id: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size > 40 ? 17 : 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                .frame(width: 44, height: 44) // hit target stays 44 pt even when the circle is smaller
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A dot that keeps rippling while recording: proof at a glance that the app is alive.
struct PulsingDot: View {
    var color: Color = Theme.ink
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color).scaleEffect(pulse ? 2.8 : 1).opacity(pulse ? 0 : 0.4)
            Circle().fill(color).opacity(pulse ? 0.55 : 1)
        }
        .frame(width: 10, height: 10)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

/// Lines that rise in one after another when a screen appears.
struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 20)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func riseIn(_ delay: Double) -> some View { modifier(RiseIn(delay: delay)) }
}
