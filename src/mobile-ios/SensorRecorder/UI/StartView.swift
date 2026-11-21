import SwiftUI
import UIKit

/// Start: nothing to fill in. The preflight checks run silently; only one that isn't passing shows,
/// as one line with its fix. Start with a failing check needs a confirm (recorded as an override).
struct StartView: View {
    @Environment(AppModel.self) private var app
    var openMenu: () -> Void
    @State private var model: PreflightModel?
    @State private var confirmOverride = false
    @State private var startError: String?
    @State private var startAfterCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CircleIconButton(systemName: "line.3.horizontal", label: "Menu", id: "menuButton", action: openMenu)
                .padding(.leading, -4)

            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Headline(lines: ["Ready", "to ride"])
                    .riseIn(0.08)
                Text("Lay the phone flat, screen up, and don't move it. The sensors do the rest.")
                    .font(Theme.font(17))
                    .lineSpacing(3) // 24 pt lines
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: 300, alignment: .leading)
                    .riseIn(0.16)
                if app.lastRecoveredCount > 0 {
                    Text("\(app.lastRecoveredCount) interrupted trip(s) were recovered. Their data is kept.")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 8)
                }
            }
            Spacer()

            VStack(spacing: 8) {
                if let model { checkLine(model) }
                Button(model?.busy == true ? "Checking…" : "Start trip") { start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model == nil || model?.busy == true)
                    .accessibilityIdentifier("startTrip")
            }
            .riseIn(0.24)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.background)
        .onAppear {
            if model == nil { model = PreflightModel(app: app) }
            model?.onAppear()
        }
        .onDisappear { model?.onDisappear() }
        // Back from a trip: the old results are stale (battery, GPS, motion test).
        .onChange(of: app.recording == nil) { _, idle in
            guard idle, let model else { return }
            model.onAppear()
            model.rerun()
        }
        .onChange(of: model?.busy ?? false) { _, busy in
            guard !busy, startAfterCheck, let model else { return }
            startAfterCheck = false
            if model.allRequiredPass { begin(overridden: false) } else { confirmOverride = true }
        }
        .alert("Start with a failing check?", isPresented: $confirmOverride) {
            Button("Start anyway", role: .destructive) { begin(overridden: true) }
                .accessibilityIdentifier("confirmOverride")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((model?.failingRequired.map { "• \($0.title): \($0.detail)" }.joined(separator: "\n") ?? "")
                 + "\n\nThe override is recorded with the trip.")
        }
        .alert("Could not start", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(startError ?? "")
        }
    }

    /// The first required check that isn't passing: grey while it is still running, red when it failed.
    @ViewBuilder private func checkLine(_ model: PreflightModel) -> some View {
        if let check = model.failingRequired.first(where: { $0.status == .fail })
            ?? (model.busy ? nil : model.failingRequired.first) {
            let failed = check.status == .fail
            HStack(spacing: 10) {
                Circle().fill(failed ? Theme.problem : Theme.muted).frame(width: 8, height: 8)
                Text(Self.headline(check, model: model))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("checkLine")
                if failed, let fix = Self.fix(check, model: model) {
                    Button(fix.label, action: fix.action)
                        .font(Theme.font(15, .semibold))
                        .underline()
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("fixCheck")
                }
            }
            .font(Theme.font(15))
            .foregroundStyle(failed ? Theme.problem : Theme.muted)
        }
    }

    private static func headline(_ c: PreflightModel.Check, model: PreflightModel) -> String {
        if c.status != .fail {
            return c.id == "gps.fix" ? "Waiting for a precise GPS fix…" : "Checking \(c.title.lowercased())…"
        }
        switch c.id {
        case "perm.location": return c.detail.contains("Precise") ? "Precise location is off" : "Location access is off"
        case "perm.motion": return "Motion access is off"
        case "avail.motion", "avail.baro": return "This phone lacks a needed sensor"
        case "gps.fix": return "No precise GPS fix yet"
        case "motion.rate": return "Motion sensors are too slow"
        case "motion.still": return "The phone moved during the check"
        case "dev.lpm": return "Low Power Mode is on"
        case "dev.battery": return "Battery low: plug the phone in"
        case "dev.thermal": return "The phone is too hot"
        case "dev.disk": return "Not enough free space"
        default: return c.title
        }
    }

    private static func fix(_ c: PreflightModel.Check, model: PreflightModel) -> (label: String, action: () -> Void)? {
        if c.id.hasPrefix("perm.") || c.id == "dev.lpm" {
            return ("Fix", {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            })
        }
        if c.id.hasPrefix("motion.") { return ("Check again", { model.rerunMotionTest() }) }
        if c.id.hasPrefix("avail.") { return nil }
        return ("Check again", { model.rerun() })
    }

    private func start() {
        guard let model, !model.busy else { return }
        let failing = model.failingRequired
        if failing.isEmpty { begin(overridden: false); return }
        // The stillness test first runs when the app opens, usually with the phone still in hand.
        // Once it's mounted, Start re-runs the 5 s motion check before offering the override.
        if failing.allSatisfy({ $0.id.hasPrefix("motion.") }) {
            startAfterCheck = true
            model.rerunMotionTest()
            return
        }
        confirmOverride = true
    }

    private func begin(overridden: Bool) {
        guard let model, !model.busy else { return }
        let result = model.result(overridden: overridden)
        model.onDisappear() // the recording takes over motion and location
        do {
            try app.startRecording(preflight: result)
        } catch {
            startError = error.localizedDescription
            model.onAppear()
        }
    }
}
