import CoreLocation
import SwiftUI
import UIKit
import UserNotifications

/// Settings → Trips (D59): the vehicle type of every trip, automatic trips and what they need.
struct TripSettingsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var vehicle = AutoStartSettings.vehicleType
    @State private var mounted = AutoStartSettings.mounted
    @State private var autoOn = AutoStartSettings.enabled
    @State private var notificationsAllowed = false
    @State private var missing: [String] = []
    @State private var turningOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trips").font(Theme.font(13, .medium)).foregroundStyle(Theme.muted)
            VStack(spacing: 0) {
                Rectangle().fill(Theme.line).frame(height: 1)
                row("Vehicle") {
                    HStack(spacing: 8) {
                        ForEach(AutoStartSettings.vehicleTypes, id: \.self) { type in
                            Button {
                                vehicle = type
                                AutoStartSettings.vehicleType = type
                            } label: {
                                Text(type.capitalized)
                                    .font(Theme.font(15, vehicle == type ? .semibold : .regular))
                                    .foregroundStyle(vehicle == type ? Theme.onInk : Theme.text)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(vehicle == type ? Theme.ink : Theme.surface))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("vehicleType.\(type)")
                            .accessibilityValue(vehicle == type ? "active" : "inactive")
                        }
                    }
                }
                toggleRow("Start trips automatically", isOn: autoOn, id: "autoStartToggle") { setAuto($0) }
                toggleRow("Phone is firmly mounted", isOn: mounted, id: "mountedToggle") {
                    mounted = $0
                    AutoStartSettings.mounted = $0
                }
                row("Location") {
                    HStack {
                        Text(locationText).foregroundStyle(app.location.isAlways ? Theme.muted : Theme.warn)
                        Spacer()
                        if !app.location.isAlways {
                            Button(app.location.canAskForAlways ? "Allow Always" : "Open Settings", action: askAlways)
                                .font(Theme.font(15, .semibold))
                                .foregroundStyle(Theme.text)
                                .underline()
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("alwaysLocation")
                        }
                    }
                }
            }
            Group {
                if !missing.isEmpty {
                    Text("Automatic trips need " + missing.joined(separator: ", ") + ".")
                        .foregroundStyle(Theme.warn)
                }
                Text("A trip starts when you drive faster than 20 km/h, and ends after 10 minutes stopped or when you walk away. "
                     + "Only firmly mounted trips count for road roughness and potholes. "
                     + "Force-quitting the app turns automatic trips off until you open it again.")
                    .foregroundStyle(Theme.muted)
            }
            .font(Theme.font(13))
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: app.location.authorization) { _, _ in refresh() }
    }

    private var locationText: String {
        switch app.location.authorization {
        case .authorizedAlways: return app.location.isFullAccuracy ? "Always, precise" : "Always, approximate"
        case .authorizedWhenInUse: return "While using the app"
        case .notDetermined: return "Not asked yet"
        default: return "Off"
        }
    }

    private func refresh() {
        app.autoTrip.notifications.status { status in
            notificationsAllowed = status == .authorized || status == .provisional
            if autoOn {
                missing = app.autoTrip.missingRequirements(notificationsAllowed: notificationsAllowed)
            }
        }
    }

    private func askAlways() {
        if app.location.canAskForAlways {
            app.location.requestAlways()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func setAuto(_ on: Bool) {
        guard on else {
            autoOn = false
            missing = []
            AutoStartSettings.enabled = false
            app.autoTrip.disarm()
            return
        }
        guard !turningOn else { return }
        turningOn = true
        // Ask for what can still be asked; anything refused before is fixed in the Settings app.
        MotionPermission.request { _ in
            app.autoTrip.notifications.requestPermission { granted in
                notificationsAllowed = granted
                if app.location.canAskForAlways && !app.location.isAlways { app.location.requestAlways() }
                missing = app.autoTrip.missingRequirements(notificationsAllowed: granted)
                turningOn = false
                if missing.isEmpty {
                    autoOn = true
                    AutoStartSettings.enabled = true
                    app.autoTrip.arm()
                }
            }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.font(15)).foregroundStyle(Theme.muted).frame(width: 92, alignment: .leading)
            content().font(Theme.font(15)).foregroundStyle(Theme.text)
        }
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func toggleRow(_ label: String, isOn: Bool, id: String, set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: set))
            .font(Theme.font(15))
            .foregroundStyle(Theme.text)
            .tint(Theme.ink)
            .frame(minHeight: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .accessibilityIdentifier(id)
            .accessibilityValue(isOn ? "active" : "inactive")
    }
}
