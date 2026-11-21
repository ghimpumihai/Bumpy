import SwiftUI

/// Upload settings (spec §6): API base URL + device key entered at runtime, never committed.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = AppSettings.baseURLString
    @State private var deviceKey = AppSettings.deviceKey
    @State private var test: UploadQueue.ProbeResult?
    @State private var testing = false
    @State private var waitingTrips = 0
    @State private var failedUploads = 0

    private var parsedURL: URL? { UploadConfig.parseBaseURL(baseURL) }
    private var urlEmpty: Bool { baseURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 6) {
                CircleIconButton(systemName: "chevron.left", label: "Back", id: "settingsBack", size: 34) { dismiss() }
                    .padding(.leading, -4)
                Text("Settings")
                    .font(Theme.font(24, .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.text)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Cloud").font(Theme.font(13, .medium)).foregroundStyle(Theme.muted)
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    field("Server") {
                        TextField("your-app.azurewebsites.net", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: baseURL) { _, _ in test = nil }
                            .accessibilityIdentifier("apiBaseURL")
                    }
                    field("Device key") {
                        SecureField("", text: $deviceKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: deviceKey) { _, _ in test = nil }
                            .accessibilityIdentifier("deviceKey")
                    }
                }
                HStack(spacing: 12) {
                    Button(action: runTest) {
                        Text("Test connection")
                            .font(Theme.font(15, .semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
                            .fixedSize()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(parsedURL == nil || testing)
                    .opacity(parsedURL == nil ? 0.4 : 1)
                    .accessibilityIdentifier("testConnection")
                    statusText
                }
                .padding(.top, 4)

                if failedUploads > 0 {
                    // Parts the server rejected (other 4xx) wait in upload_failed/; once the backend is
                    // fixed, this sends them again, oldest first.
                    Button(action: retryFailed) {
                        HStack {
                            Text("Retry failed uploads (\(failedUploads))")
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                        }
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.warn)
                        .frame(minHeight: 52)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .accessibilityIdentifier("retryFailedUploads")
                }
            }

            Spacer(minLength: 0)
            Text("Version \(AppInfo.shortVersion) · \(AppInfo.modelName)")
                .font(Theme.font(13))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.keyboard) // the footer stays at the bottom; the fields are near the top
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { save() }
        .task {
            while !Task.isCancelled {
                let queue = app.uploadQueue
                // Directory listing: never on the main thread.
                let counts = await Task.detached(priority: .utility) { (queue.waitingTripCount(), queue.failedFiles().count) }.value
                (waitingTrips, failedUploads) = counts
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var waitingText: String {
        switch waitingTrips {
        case 0: return "nothing waiting"
        case 1: return "1 trip waiting"
        default: return "\(waitingTrips) trips waiting"
        }
    }

    /// Grey when fine; red with a dot when the test failed or the address can't be used.
    @ViewBuilder private var statusText: some View {
        Group {
            if urlEmpty {
                Text("Upload off · \(waitingText)").foregroundStyle(Theme.muted)
            } else if parsedURL == nil {
                problem("Use https://")
            } else if testing {
                Text("Checking…").foregroundStyle(Theme.muted)
            } else if let test {
                if test.ok {
                    Text("\(test.short) · \(waitingText)").foregroundStyle(Theme.muted)
                } else {
                    problem("\(test.short) · \(waitingText)")
                }
            } else {
                Text(waitingText.prefix(1).uppercased() + waitingText.dropFirst()).foregroundStyle(Theme.muted)
            }
        }
        .font(Theme.font(14))
        .lineLimit(2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
    }

    private func problem(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.problem).frame(width: 6, height: 6)
            Text(text)
        }
        .foregroundStyle(Theme.problem)
    }

    private func field<F: View>(_ label: String, @ViewBuilder content: () -> F) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.font(15)).foregroundStyle(Theme.muted).frame(width: 92, alignment: .leading)
            content().font(Theme.font(15)).foregroundStyle(Theme.text)
        }
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func runTest() {
        save()
        testing = true
        Task {
            test = await UploadQueue.testConnection(config: AppSettings.uploadConfig)
            testing = false
        }
    }

    private func retryFailed() {
        let queue = app.uploadQueue
        failedUploads = 0
        Task.detached(priority: .userInitiated) { queue.requeueFailed() }
    }

    private func save() {
        AppSettings.baseURLString = baseURL
        AppSettings.deviceKey = deviceKey
        app.uploadQueue.kick()
    }
}
