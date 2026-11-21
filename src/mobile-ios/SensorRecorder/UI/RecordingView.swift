import SwiftUI

/// While recording: a ticking timer (proof it's alive), one status line, and the only control,
/// a 2 s hold to end the trip (spec §8: no single-tap stop, no pause).
struct RecordingView: View {
    let controller: RecordingController
    var openMenu: () -> Void

    var body: some View {
        let status = controller.statusLine
        VStack(spacing: 20) {
            CircleIconButton(systemName: "line.3.horizontal", label: "Menu", id: "menuButton", action: openMenu)
                .padding(.leading, -4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
            Text(TripFormat.timer(controller.snapshot.elapsed))
                .font(.system(size: 96, weight: .semibold))
                .tracking(-4)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("elapsed")
                .riseIn(0.12)
            HStack(spacing: 10) {
                PulsingDot()
                Text("Recording")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.text)
            .riseIn(0.22)
            Spacer()

            HStack(spacing: 6) {
                if status.level != .ok {
                    Circle().fill(Theme.color(status.level)).frame(width: 6, height: 6)
                }
                Text(status.text)
                    .multilineTextAlignment(.center)
            }
            .font(.system(size: 15))
            .foregroundStyle(Theme.color(status.level))
            .animation(.easeInOut(duration: 0.3), value: status.text)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("statusLine")
            .accessibilityValue(status.level.label)
            .riseIn(0.3)

            HoldToEndButton { controller.stop() }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .persistentSystemOverlays(.hidden)
    }
}

/// Stop needs a 2 s long-press (spec §8): no accidental stop, no pause.
struct HoldToEndButton: View {
    let action: () -> Void
    @State private var pressing = false
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14).fill(Theme.ink)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.22))
                    .frame(width: g.size.width * progress)
            }
            Text(pressing ? "Keep holding…" : "Hold to end trip")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.onInk)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .scaleEffect(pressing ? 0.98 : 1)
        .animation(.easeOut(duration: 0.2), value: pressing)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 2, maximumDistance: 40) {
            progress = 0
            pressing = false
            action()
        } onPressingChanged: { p in
            pressing = p
            withAnimation(p ? .linear(duration: 2) : .easeOut(duration: 0.2)) { progress = p ? 1 : 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("Hold for two seconds to end the trip")
        .accessibilityIdentifier("holdToStop")
        .accessibilityAddTraits(.isButton)
    }
}
