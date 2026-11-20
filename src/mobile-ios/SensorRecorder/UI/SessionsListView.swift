import SwiftUI

/// Screen 1: past sessions + New session.
struct SessionsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.lastRecoveredCount > 0 {
                Section {
                    Label("\(model.lastRecoveredCount) interrupted session(s) were recovered. Their data up to the interruption is kept.",
                          systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.warn)
                        .font(.footnote)
                }
            }
            Section("Sessions") {
                if model.sessions.isEmpty {
                    Text(model.isRecovering ? "Loading…" : "No sessions yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sessions) { entry in
                    NavigationLink(value: Route.detail(entry.folder.lastPathComponent)) {
                        SessionRow(entry: entry)
                    }
                    .accessibilityIdentifier("session.\(entry.folder.lastPathComponent)")
                }
            }
        }
        .refreshable { model.refreshSessions() }
        .navigationTitle("Sensor Recorder")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: Route.help) { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("Drive protocol help")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.path.append(Route.setup)
            } label: {
                Label("New session", systemImage: "record.circle")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.problem)
            .padding()
            .background(.ultraThinMaterial)
            .accessibilityIdentifier("newSessionButton")
        }
        .onAppear { model.refreshSessions() }
    }
}

struct SessionRow: View {
    let entry: SessionStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? entry.folder.lastPathComponent)
                    .font(.headline)
                Spacer()
                if entry.isRecovered { Badge(text: "RECOVERED", color: Theme.warn) }
                if entry.metadata?.syntheticSensors == true { Badge(text: "SYNTHETIC", color: Theme.neutral) }
                if entry.isUnreadable { Badge(text: "NO METADATA", color: Theme.problem) }
            }
            HStack(spacing: 12) {
                Label(entry.durationSec.map(DurationFormat.hms) ?? "–", systemImage: "clock")
                Label(ByteFormat.string(entry.sizeBytes), systemImage: "internaldrive")
                if let v = entry.metadata?.vehicle.type { Label(v, systemImage: "car") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(entry.folder.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}
