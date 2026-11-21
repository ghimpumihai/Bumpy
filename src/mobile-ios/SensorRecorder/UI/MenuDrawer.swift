import SwiftUI

/// The burger menu: a panel from the left over a dimmed screen. Nothing in it can stop a trip.
struct MenuDrawer: View {
    @Binding var isOpen: Bool
    var onSettings: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.scrim
                .ignoresSafeArea()
                .opacity(isOpen ? 1 : 0)
                .allowsHitTesting(isOpen)
                .onTapGesture { isOpen = false }
                .accessibilityHidden(true)

            panel
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(
                    UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28)
                        .fill(Theme.background)
                        .shadow(color: .black.opacity(0.12), radius: 20, x: 8)
                        .ignoresSafeArea()
                )
                .offset(x: isOpen ? 0 : -330)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: isOpen)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack {
                Text("Road & Ride")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.text)
                Spacer()
                CircleIconButton(systemName: "xmark", label: "Close menu", id: "closeMenu") { isOpen = false }
            }

            VStack(alignment: .leading, spacing: 6) {
                if let url = AppSettings.dashboardURL {
                    item(icon: "globe", title: "Web app", hint: "Your trips and the map", trailing: "arrow.up.right",
                         id: "menuWebApp", delay: 0.14) { openURL(url) }
                }
                item(icon: "slider.horizontal.3", title: "Settings", hint: "Cloud and recording", trailing: "chevron.right",
                     id: "settingsButton", delay: 0.21) {
                    isOpen = false
                    onSettings()
                }
            }

            Spacer()
            Text("Version \(AppInfo.version)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 4)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }

    private func item(icon: String, title: String, hint: String, trailing: String, id: String, delay: Double,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .frame(width: 48, height: 48)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(hint).font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .foregroundStyle(Theme.text)
            .frame(minHeight: 68)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isOpen ? 1 : 0)
        .offset(x: isOpen ? 0 : -16)
        .animation(.easeOut(duration: 0.4).delay(isOpen ? delay : 0), value: isOpen)
        .accessibilityIdentifier(id)
    }
}
