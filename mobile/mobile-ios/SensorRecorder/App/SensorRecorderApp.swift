import SwiftUI

@main
struct SensorRecorderApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
                .tint(Theme.ink)
                .onAppear { model.onLaunch() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}

/// Start → (cover) Recording → Recap. The burger menu and Settings are reachable from every screen.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WithMenu { openMenu in
            StartView(openMenu: openMenu)
        }
        .fullScreenCover(isPresented: Binding(get: { model.recording != nil }, set: { _ in })) {
            if let rec = model.recording {
                RecordingFlowView(controller: rec)
                    .environment(model)
                    .preferredColorScheme(.light)
                    .interactiveDismissDisabled(true)
            }
        }
    }
}

/// Recording while it runs, the recap after Stop.
struct RecordingFlowView: View {
    let controller: RecordingController
    @Environment(AppModel.self) private var model

    var body: some View {
        WithMenu { openMenu in
            if let meta = controller.finished {
                RecapView(metadata: meta, trackPoints: controller.trackPoints, openMenu: openMenu) {
                    model.closeRecording()
                }
                .transition(.opacity.combined(with: .offset(y: 16)))
            } else {
                RecordingView(controller: controller, openMenu: openMenu)
                    .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: controller.isFinished)
    }
}

/// A screen with the burger menu over it and Settings pushed from the right.
struct WithMenu<Content: View>: View {
    @ViewBuilder var content: (_ openMenu: @escaping () -> Void) -> Content
    @State private var menuOpen = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content { menuOpen = true }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showSettings) { SettingsView() }
        }
        .overlay { MenuDrawer(isOpen: $menuOpen) { showSettings = true } }
    }
}
