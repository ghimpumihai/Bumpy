import SwiftUI

/// Upload settings (spec §6): API base URL + device key entered at runtime, never committed;
/// the road-noise toggle.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = AppSettings.baseURLString
    @State private var deviceKey = AppSettings.deviceKey
    @State private var roadNoise = AppSettings.recordRoadNoise
    @State private var test: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var waiting = 0

    private var parsedURL: URL? { UploadConfig.parseBaseURL(baseURL) }
    private var urlEmpty: Bool { baseURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 6) {
                    CircleIconButton(systemName: "chevron.left", label: "Back", id: "settingsBack", size: 34) { dismiss() }
                        .padding(.leading, -8)
                    Text("Settings")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.text)
                }

                section("Cloud") {
                    VStack(spacing: 0) {
                        Divider().overlay(Theme.line)
                        field("Server") {
                            TextField("your-app.azurewebsites.net", text: $baseURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("apiBaseURL")
                        }
                        field("Device key") {
                            SecureField("", text: $deviceKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("deviceKey")
                        }
                    }
                    HStack(spacing: 12) {
                        Button {
                            runTest()
                        } label: {
                            Text("Test connection")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(parsedURL == nil || testing)
                        .accessibilityIdentifier("testConnection")
                        statusText
                    }
                    .padding(.top, 4)
                }

                section("Recording") {
                    Toggle(isOn: $roadNoise) {
                        Text("Record road noise").font(.system(size: 17)).foregroundStyle(Theme.text)
                    }
                    .tint(Theme.ink)
                    .frame(minHeight: 52)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .accessibilityIdentifier("audioToggle")
                    .accessibilityValue(roadNoise ? "active" : "inactive")
                    Text("Off: only the noise level is measured. On: audio is kept on this phone, never sent live. Tell everyone in the vehicle.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }

                Text("Version \(AppInfo.version) · \(AppInfo.modelName)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: roadNoise) { _, v in AppSettings.recordRoadNoise = v }
        .onDisappear { save() }
        .task {
            while !Task.isCancelled {
                let queue = app.uploadQueue
                waiting = await Task.detached(priority: .utility) { () -> Int in
                    queue.refreshCounts() // directory listing: never on the main thread
                    return queue.status.queueCount
                }.value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        let waitingText = waiting == 0 ? "nothing waiting" : "\(waiting) waiting"
        Group {
            if urlEmpty {
                Text("Upload off · \(waitingText)").foregroundStyle(Theme.muted)
            } else if parsedURL == nil {
                Text("Use https://").foregroundStyle(Theme.problem)
            } else if testing {
                Text("Checking…").foregroundStyle(Theme.muted)
            } else if let test {
                Text(test.ok ? "Connected · \(waitingText)" : "\(test.text) · \(waitingText)")
                    .foregroundStyle(test.ok ? Theme.muted : Theme.problem)
            }
        }
        .font(.system(size: 14))
        .lineLimit(2)
        .accessibilityIdentifier("connectionStatus")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            content()
        }
    }

    private func field<F: View>(_ label: String, @ViewBuilder content: () -> F) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.muted).frame(width: 92, alignment: .leading)
            content().font(.system(size: 15)).foregroundStyle(Theme.text)
        }
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func runTest() {
        save()
        testing = true
        Task {
            let r = await UploadQueue.testConnection(config: AppSettings.uploadConfig)
            test = (r.ok, r.detail)
            testing = false
        }
    }

    private func save() {
        AppSettings.baseURLString = baseURL
        AppSettings.deviceKey = deviceKey
        app.uploadQueue.kick()
    }
}
