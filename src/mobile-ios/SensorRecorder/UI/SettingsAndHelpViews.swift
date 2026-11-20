import SwiftUI

/// Upload settings (spec §6): API base URL + device key entered at runtime, never committed.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var baseURL = AppSettings.baseURLString
    @State private var deviceKey = AppSettings.deviceKey
    @State private var testResult: String?
    @State private var testing = false
    @State private var status = UploadStatus()
    @State private var confirmClear = false

    private var parsedURL: URL? { UploadConfig.parseBaseURL(baseURL) }

    var body: some View {
        Form {
            Section {
                TextField("https://<function-app>.azurewebsites.net", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("apiBaseURL")
                SecureField("Device key", text: $deviceKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("deviceKey")
                if baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("UPLOAD OFF (local only)").font(.footnote.bold()).foregroundStyle(Theme.neutral)
                } else if parsedURL == nil {
                    Text("Invalid URL: use https:// (http:// only for a local test server)").font(.footnote).foregroundStyle(Theme.problem)
                } else if let url = parsedURL {
                    Text("POST \(url.appendingPathComponent("api/ingest").absoluteString)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Button("Save") { save() }.accessibilityIdentifier("saveSettings")
                Button {
                    save()
                    Task {
                        testing = true
                        let r = await UploadQueue.testConnection(config: AppSettings.uploadConfig)
                        testResult = (r.ok ? "✓ " : "✗ ") + r.detail
                        testing = false
                    }
                } label: {
                    HStack { Text("Test connection (probe POST /api/ingest)"); if testing { Spacer(); ProgressView() } }
                }
                .disabled(parsedURL == nil || testing)
                if let testResult { Text(testResult).font(.footnote) }
            } header: {
                Text("Azure upload (live, when an API URL is set)")
            } footer: {
                Text("Empty URL = upload disabled. Recording always works fully offline; batches are queued on disk and uploaded when possible. The key is stored in the Keychain.")
            }

            Section("Upload queue") {
                LabeledContent("Status", value: status.enabled ? "enabled" : "off")
                LabeledContent("Queued batches", value: "\(status.queueCount)")
                LabeledContent("Uploaded (this launch)", value: "\(status.uploadedCount)")
                LabeledContent("Failed (rejected)", value: "\(status.failedCount)")
                if let e = status.lastError { LabeledContent("Last error", value: e) }
                Button("Retry now") { app.uploadQueue.kick() }
                Button("Move failed batches back to queue") { app.uploadQueue.requeueFailed() }
                    .disabled(status.failedCount == 0)
                Button("Clear upload queue…", role: .destructive) { confirmClear = true }
                    .disabled(status.queueCount == 0)
            }

            Section("About") {
                LabeledContent("App", value: AppInfo.version)
                LabeledContent("Device", value: "\(AppInfo.modelName) (\(AppInfo.modelIdentifier))")
                LabeledContent("Device ID", value: AppSettings.deviceId).font(.caption)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                let queue = app.uploadQueue
                status = await Task.detached(priority: .utility) { () -> UploadStatus in
                    queue.refreshCounts() // directory listing: never on the main thread
                    return queue.status
                }.value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .confirmationDialog("Delete all queued upload batches? Session files on disk are NOT affected.",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear queue", role: .destructive) {
                let queue = app.uploadQueue
                Task.detached(priority: .userInitiated) { queue.clearPending() }
            }
        }
        .onDisappear { save() }
    }

    private func save() {
        AppSettings.baseURLString = baseURL
        AppSettings.deviceKey = deviceKey
        app.uploadQueue.kick()
    }
}

/// Drive protocol (spec §9), shown in-app for the operator.
struct HelpView: View {
    var body: some View {
        List {
            Section("Before driving") {
                step(1, "Phone charged and plugged into the car charger. Low Power Mode OFF, Do Not Disturb ON.")
                step(2, "Mount the phone rigidly: taped or clamped flat on the center console, screen up, top of phone toward the vehicle front. Avoid wobbly air-vent mounts, which add their own vibration. Never move it during the drive; if it moves, press PHONE MOVED.")
                step(3, "Fill in the session setup and take the mount photo.")
                step(4, "Run the preflight; everything must be green.")
                step(5, "Start recording, then press SYNC TAP and knock firmly 3 times on the phone/mount.")
                step(6, "Stationary baselines: 30 s engine off, then 30 s engine idling (label Idle).")
            }
            Section("During the drive (label everything)") {
                bullet("Smooth asphalt, straight, constant speed (baseline)")
                bullet("Cobblestones, rough or patched asphalt, potholes, speed bumps, tram rails")
                bullet("Winding road / roundabouts / curves (lateral sway, the main sickness driver)")
                bullet("Stop-and-go traffic (longitudinal sway)")
                bullet("Some faster road segment if possible")
                bullet("If possible, drive one rough segment twice at different speeds (e.g. 20 and 40 km/h). This lets us prove the speed normalization works.")
                bullet("Sickness ratings every 2 min from a rear passenger (the app prompts).")
                bullet("The operator is a passenger, never the driver.")
            }
            Section("After the drive") {
                step(1, "30 s stationary with the engine idling, then SYNC TAP + 3 knocks, then hold to Stop.")
                step(2, "Check the summary screen for red rows.")
                step(3, "Immediately export the session folder (AirDrop to a laptop, plus Files → iCloud Drive or another copy). Keep two copies before doing anything else.")
            }
            Section("Dry run first") {
                Text("Do a 5–10 minute test (walk or drive around the block), export it and run tools/quick_check.py on a laptop: motion ~100 Hz with max gap < 0.1 s, GPS ~1 Hz with sane coordinates, labels present, audio plays, t_utc_ms is the correct real time.")
                    .font(.subheadline)
            }
        }
        .navigationTitle("Drive protocol")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.headline.monospacedDigit()).frame(width: 22, height: 22)
                .background(Theme.accent.opacity(0.25), in: Circle())
            Text(text).font(.subheadline)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text).font(.subheadline)
        }
    }
}
