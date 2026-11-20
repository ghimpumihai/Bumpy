import SwiftUI
import UIKit

/// Screen 3: preflight checklist. Start is blocked until required checks pass (override possible).
struct PreflightView: View {
    @Environment(AppModel.self) private var app
    @State private var model: PreflightModel?
    @State private var confirmOverride = false
    @State private var startError: String?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Preflight")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = PreflightModel(app: app) }
            model?.onAppear()
        }
        .onDisappear { model?.onDisappear() }
    }

    @ViewBuilder
    private func content(_ model: PreflightModel) -> some View {
        List {
            Section {
                ForEach(model.checks) { check in
                    CheckRow(check: check)
                        .accessibilityElement(children: .combine) // one element: title + detail + status
                        .accessibilityValue(check.status.rawValue)
                        .accessibilityIdentifier("check.\(check.id)")
                }
            } footer: {
                Text("Required checks must be green. The motion test needs the vehicle stopped and the phone untouched for 5 s.")
            }
            if model.motionTestRunning {
                Section {
                    ProgressView(value: model.motionTestProgress) {
                        Text("Motion test: keep still…")
                    }
                }
            }
            Section {
                if model.needsSettings {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Label("Open Settings to grant permissions", systemImage: "gear")
                    }
                    .accessibilityIdentifier("openSettings")
                }
                Button {
                    model.rerunMotionTest()
                } label: {
                    Label("Re-run motion test", systemImage: "waveform.path.ecg")
                }
                .disabled(model.busy)
                Button {
                    model.rerun()
                } label: {
                    Label("Re-run all checks", systemImage: "arrow.clockwise")
                }
                .disabled(model.running)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.allRequiredPass {
                    Button {
                        start(model, overridden: false)
                    } label: {
                        Label("START RECORDING", systemImage: "record.circle.fill")
                            .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ok)
                    .foregroundStyle(Theme.onBright) // contrast on green
                    .disabled(model.busy)
                    .accessibilityIdentifier("startRecording")
                } else {
                    Text(model.busy ? "Checks running…" : "\(model.failingRequired.count) required check(s) not passing")
                        .font(.footnote).foregroundStyle(Theme.warn)
                    Button {
                        confirmOverride = true
                    } label: {
                        Text("Override & start anyway").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.warn)
                    .disabled(model.busy) // checks (incl. the motion test on the shared motion manager) still running
                    .accessibilityIdentifier("preflightOverride")
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .alert("Start with failing checks?", isPresented: $confirmOverride) {
            Button("Start anyway", role: .destructive) { start(model, overridden: true) }
                .accessibilityIdentifier("confirmOverride")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.failingRequired.map { "• \($0.title): \($0.detail)" }.joined(separator: "\n")
                 + "\n\nThe override is recorded in session.json.")
        }
        .alert("Could not start", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(startError ?? "")
        }
    }

    private func start(_ model: PreflightModel, overridden: Bool) {
        guard !model.busy else { return }
        do {
            try app.startRecording(preflight: model.result(overridden: overridden))
        } catch {
            startError = error.localizedDescription
        }
    }
}

private struct CheckRow: View {
    let check: PreflightModel.Check

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(check.title).font(.body.weight(.medium))
                    if !check.required { Text("optional").font(.caption2).foregroundStyle(.secondary) }
                }
                if !check.detail.isEmpty {
                    Text(check.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch check.status {
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(Theme.neutral)
        case .running: ProgressView()
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.problem)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(Theme.neutral)
        }
    }
}
