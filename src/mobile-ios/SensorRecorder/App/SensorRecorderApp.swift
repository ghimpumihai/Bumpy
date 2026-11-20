import SwiftUI

@main
struct SensorRecorderApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { model.onLaunch() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            SessionsListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .setup: SessionSetupView()
                    case .preflight: PreflightView()
                    case .detail(let name): SessionDetailView(folderName: name)
                    case .settings: SettingsView()
                    case .help: HelpView()
                    }
                }
        }
        .fullScreenCover(isPresented: Binding(get: { model.recording != nil }, set: { _ in })) {
            if let rec = model.recording {
                RecordingFlowView(controller: rec)
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .interactiveDismissDisabled(true)
            }
        }
    }
}

/// Dashboard while recording, summary after Stop.
struct RecordingFlowView: View {
    let controller: RecordingController
    @Environment(AppModel.self) private var model

    var body: some View {
        if let meta = controller.finished {
            NavigationStack {
                SessionSummaryView(metadata: meta, folder: controller.session.folder) {
                    model.closeRecording()
                }
            }
        } else {
            RecordingDashboardView(controller: controller)
        }
    }
}
