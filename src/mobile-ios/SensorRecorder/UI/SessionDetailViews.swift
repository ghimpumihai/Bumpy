import SwiftUI
import UIKit

/// Screen 5: shown right after Stop. "Did we get good data?" + Export.
struct SessionSummaryView: View {
    let metadata: SessionMetadata
    let folder: URL
    var onDone: () -> Void
    @State private var exported = false
    @State private var confirmDone = false

    var body: some View {
        List {
            Section {
                DataVerdictRow(metadata: metadata)
                Label("Export now and keep TWO copies before doing anything else.", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(Theme.warn)
                    .font(.subheadline.weight(.semibold))
            }
            SessionStatsSections(metadata: metadata, folder: folder)
            // Counts only once a share activity completed: a cancelled sheet is not an export.
            ExportSection(folder: folder, sessionId: metadata.sessionId, onExported: { exported = true })
        }
        .navigationTitle("Session summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if exported { onDone() } else { confirmDone = true }
                }
                .accessibilityIdentifier("summaryDone")
            }
        }
        .confirmationDialog("Not exported yet. The data stays on the phone (Sessions list, Files app), but the protocol says export immediately.",
                            isPresented: $confirmDone, titleVisibility: .visible) {
            Button("Close without exporting") { onDone() }
                .accessibilityIdentifier("closeWithoutExport")
            Button("Stay and export", role: .cancel) {}
        }
    }
}

/// "Did we get good data?" in one line, at the top of the summary.
struct DataVerdictRow: View {
    let metadata: SessionMetadata

    var body: some View {
        let v = SessionVerdict(metadata: metadata)
        Label(v.text, systemImage: v.ok ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
            .font(.headline)
            .foregroundStyle(v.ok ? Theme.ok : Theme.problem)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dataVerdict")
    }
}

/// Session detail from the list (also works for recovered sessions).
struct SessionDetailView: View {
    let folderName: String
    @Environment(AppModel.self) private var app
    @State private var entry: SessionStore.Entry?
    @State private var confirmDelete = false
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let folder = app.store.root.appendingPathComponent(folderName, isDirectory: true)
        List {
            if let meta = entry?.metadata {
                if meta.recovered {
                    Section {
                        Label("Recovered: the app was terminated while recording. Data up to that point is intact; stats were rebuilt from the files.",
                              systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.warn).font(.footnote)
                    }
                }
                SessionStatsSections(metadata: meta, folder: folder)
            } else if entry != nil {
                Section { Text("session.json is missing or unreadable. Raw files are listed below.").foregroundStyle(Theme.problem) }
                FilesSection(folder: folder)
            } else {
                ProgressView()
            }
            ExportSection(folder: folder, sessionId: entry?.metadata?.sessionId)
            Section {
                Button("Delete session…", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("deleteSession")
                if let deleteError { Text(deleteError).font(.footnote).foregroundStyle(Theme.problem) }
            } footer: {
                Text("Deletes all files of this session from the phone (CSV, audio, photo). Refused while batches are still waiting to upload. Export first.")
            }
        }
        .confirmationDialog("Delete this session permanently? This cannot be undone. Make sure it is exported.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task {
                    do {
                        try await app.deleteSession(folder: folder, sessionId: entry?.metadata?.sessionId)
                        dismiss()
                    } catch {
                        deleteError = "Could not delete: \(error.localizedDescription)"
                    }
                }
            }
            .accessibilityIdentifier("confirmDeleteSession")
        }
        .navigationTitle(entry?.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? folderName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let store = app.store
            entry = await Task.detached { store.entry(for: folder) }.value
        }
    }
}

struct SessionStatsSections: View {
    let metadata: SessionMetadata
    let folder: URL

    private var orderedStreams: [(StreamID, SessionMetadata.StreamStats)] {
        StreamID.allCases.compactMap { id in metadata.stats?.streams[id.rawValue].map { (id, $0) } }
    }

    var body: some View {
        Section("Session") {
            row("Folder", metadata.folderName)
            row("Started", ISO8601.date(metadata.startedAtUtc)?.formatted(date: .abbreviated, time: .standard) ?? metadata.startedAtUtc)
            row("Duration", metadata.stats.map { DurationFormat.hms($0.durationSec) } ?? "–")
            row("Vehicle", [metadata.vehicle.type, metadata.vehicle.makeModel].filter { !$0.isEmpty }.joined(separator: " · "))
            row("Mount", metadata.mount.location)
            row("Device", "\(metadata.device.name) · iOS \(metadata.device.iosVersion)")
            row("App", metadata.appVersion)
            if metadata.syntheticSensors { row("Sensors", "SYNTHETIC (simulator/test)") }
            if metadata.preflight?.overridden == true { row("Preflight", "OVERRIDDEN") }
        }
        if let stats = metadata.stats {
            Section {
                ForEach(orderedStreams, id: \.0) { id, s in
                    let bad = s.maxGapSec > id.significantGap
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(id.displayName).font(.body.weight(.semibold))
                            if bad { Text("GAP").font(.caption2.bold()).foregroundStyle(Theme.problem) } // not colour-only
                            Spacer()
                            Text(String(format: "%.1f Hz", s.meanRateHz)).font(.body.monospacedDigit())
                        }
                        HStack {
                            Text("\(s.samples) samples")
                            Spacer()
                            Text(String(format: "max gap %.2f s", s.maxGapSec))
                            if s.gapsOver1s > 0 { Text("· \(s.gapsOver1s)× >1 s") }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(bad ? Theme.problem : .secondary)
                    }
                    .listRowBackground(bad ? Theme.problem.opacity(0.15) : nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(s.samples) samples")
                    .accessibilityIdentifier("stat.\(id.rawValue)")
                }
            } header: {
                Text("Streams")
            } footer: {
                Text("Red = data gap: > 1 s for motion and audio level, > 3 s for GPS (nominal 1 Hz). Barometer, heading, activity and device health are event/slow streams; gaps are normal there.")
            }
            Section("Labels") {
                row("Labels", "\(stats.labelsCount)")
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(stats.labelsCount)")
                    .accessibilityIdentifier("stat.labelsCount")
            }
            Section("Storage") {
                row("Total size", ByteFormat.string(stats.totalBytes))
                row("Audio files", stats.audioFiles.isEmpty ? "none" : stats.audioFiles.joined(separator: ", "))
                row("Write errors", "\(stats.writeErrors)", color: stats.writeErrors > 0 ? Theme.problem : nil)
                row("Upload batches queued", "\(stats.uploadBatchesCreated)")
            }
        } else {
            Section { Text("No stats (session not finished).").foregroundStyle(.secondary) }
        }
        FilesSection(folder: folder)
    }

    private func row(_ k: String, _ v: String, color: Color? = nil) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing).foregroundStyle(color ?? .primary)
        }
        .font(.subheadline)
    }
}

private struct FilesSection: View {
    let folder: URL
    @State private var files: [(String, Int64)] = []

    var body: some View {
        Section("Files") {
            ForEach(files, id: \.0) { name, size in
                HStack {
                    Text(name).font(.caption.monospaced())
                    Spacer()
                    Text(ByteFormat.string(size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            let folder = self.folder
            files = await Task.detached(priority: .userInitiated) { () -> [(String, Int64)] in
                let fm = FileManager.default
                let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                return names.sorted().map { ($0, fm.fileSize(folder.appendingPathComponent($0))) }
            }.value
        }
    }
}

/// Export: zip the folder (system zip via NSFileCoordinator, no dependencies) → share sheet
/// (AirDrop, Save to Files / iCloud Drive…), or jump to the folder in the Files app.
struct ExportSection: View {
    let folder: URL
    let sessionId: String?
    /// Called when a share activity completed (not when the zip is merely built).
    var onExported: () -> Void = {}
    @Environment(AppModel.self) private var app
    @State private var exportState: ExportState = .idle
    @State private var queued = 0

    var body: some View {
        Section {
            Button {
                export()
            } label: {
                HStack {
                    Label("Export session (zip)", systemImage: "square.and.arrow.up")
                    if exportState.isBusy { Spacer(); ProgressView() }
                }
                .font(.headline)
            }
            .disabled(exportState.isBusy)
            .accessibilityIdentifier("exportButton")

            Button {
                openInFiles()
            } label: {
                Label("Show folder in Files app", systemImage: "folder")
            }
            .accessibilityIdentifier("showInFiles")

            if let sessionId {
                Button {
                    app.uploadQueue.kick()
                    queued = app.uploadQueue.pendingCount(sessionId: sessionId)
                } label: {
                    Label(AppSettings.uploadConfig.isEnabled ? "Upload full session (\(queued) batches queued)" : "Upload OFF – set API URL in Settings",
                          systemImage: "icloud.and.arrow.up")
                }
                .disabled(!AppSettings.uploadConfig.isEnabled)
                .accessibilityIdentifier("uploadFullSession")
            }
            exportStatus
            if AppSettings.uploadConfig.isEnabled {
                let st = app.uploadQueue.status
                LabeledContent("Upload status",
                               value: "\(queued) queued (this session) · \(st.uploadedCount) sent · \(st.failedCount) failed")
                    .font(.footnote)
                if let e = st.lastError { LabeledContent("Last upload error", value: e).font(.footnote) }
            } else {
                LabeledContent("Upload status", value: "OFF – local only").font(.footnote)
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Raw audio is never sent live; it is only in the session folder and the export. Exclude *.m4a when uploading folders to the cloud if audio must stay on the phone.")
        }
        .task {
            if let sessionId { queued = app.uploadQueue.pendingCount(sessionId: sessionId) }
        }
    }

    @ViewBuilder private var exportStatus: some View {
        switch exportState {
        case .idle, .zipping:
            EmptyView()
        case let .sharing(name, bytes, error):
            exportResultLabel("Ready: \(name) · \(ByteFormat.string(bytes))", icon: "checkmark.seal.fill", color: Theme.ok)
            if let error { Text("Last attempt failed: \(error)").foregroundStyle(Theme.problem).font(.footnote) }
        case let .exported(name, bytes):
            exportResultLabel("Exported: \(name) · \(ByteFormat.string(bytes))", icon: "checkmark.seal.fill", color: Theme.ok)
        case let .cancelled(name, _):
            exportResultLabel("Not exported: share cancelled (\(name))", icon: "exclamationmark.triangle.fill", color: Theme.warn)
        case let .failed(message):
            Text(message).foregroundStyle(Theme.problem).font(.footnote)
        }
    }

    private func exportResultLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(color)
            .accessibilityElement(children: .combine) // one element, not icon + text
            .accessibilityIdentifier("exportResult")
    }

    private func export() {
        exportState = .zipping
        let folder = self.folder
        Task.detached(priority: .userInitiated) {
            let result = Result { () throws -> (URL, Int64) in
                let url = try FolderZipper.zip(folder)
                return (url, FileManager.default.fileSize(url))
            }
            await MainActor.run {
                switch result {
                case let .success((url, bytes)):
                    exportState = .sharing(name: url.lastPathComponent, bytes: bytes)
                    SharePresenter.share(url) { completed, activity, error in
                        shareFinished(zip: url, completed: completed, activity: activity, error: error)
                    }
                case .failure(let e):
                    exportState = .failed("Export failed: \(e.localizedDescription)")
                }
            }
        }
    }

    private func shareFinished(zip: URL, completed: Bool, activity: String?, error: String?) {
        let (next, sheetClosed) = exportState.shareFinished(completed: completed, activity: activity, error: error)
        exportState = next
        if case .exported = next { onExported() }
        if sheetClosed {
            Task.detached(priority: .utility) { FolderZipper.removeExport(zip) }
        }
    }

    private func openInFiles() {
        // `shareddocuments://` opens the Files app at a path inside our (file-shared) Documents.
        if let url = URL(string: "shareddocuments://" + folder.path) {
            UIApplication.shared.open(url)
        }
    }
}


/// Presents the system share sheet from the top-most view controller via UIKit.
///
/// Why not a SwiftUI `.sheet` + `UIViewControllerRepresentable`: declared inside a lazy `List`
/// within the recording `fullScreenCover`, that presentation tore down the cover (seen in the
/// end-to-end run: the summary vanished and the app fell back to Preflight).
enum SharePresenter {
    /// `completion(completed, activityType, error)` runs on the main thread each time an activity
    /// ends, and once with `activityType == nil` when the sheet is dismissed without one.
    @MainActor
    static func share(_ url: URL, completion: @escaping @MainActor (Bool, String?, String?) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else {
            completion(false, nil, "no window to present the share sheet")
            return
        }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.completionWithItemsHandler = { activity, completed, _, error in
            let activityName = activity?.rawValue, message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(completed, activityName, message) }
            }
        }
        top.present(vc, animated: true)
    }
}
