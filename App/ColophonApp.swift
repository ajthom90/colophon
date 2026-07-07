import SwiftUI

#if DEBUG && os(macOS)
/// Headless perf-spike hook: if `COLOPHON_PERF_AUTOSCROLL=1` is set, opens the
/// `perf-spike` Window on launch so the scroll-sweep in `PerfSpikeView` can run without
/// any human clicking Window ▸ Perf Spike first.
private struct PerfSpikeAutoOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .task {
                guard ProcessInfo.processInfo.environment["COLOPHON_PERF_AUTOSCROLL"] == "1" else { return }
                PerfSpikeClock.windowOpenRequestedAt = Date()
                openWindow(id: "perf-spike")
            }
    }
}
#endif

@main
struct ColophonApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG && os(macOS)
        PerfSpikeClock.processLaunch = Date()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // Boot flow: any stored connection → the `ConnectionsView` hub (which auto-resumes
                // the last-active one, cached-first, even with the server down); otherwise the
                // first-run `ConnectView`. `ConnectionsView` owns its own `NavigationStack` and
                // pushes `LibrariesView` on activation.
                if app.connections.isEmpty {
                    NavigationStack { ConnectView() }
                } else {
                    ConnectionsView()
                }
            }
            .safeAreaInset(edge: .bottom) { PlayerBarView() }
            .alert("Something went wrong", isPresented: Binding(
                get: { app.errorMessage != nil },
                set: { if !$0 { app.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(app.errorMessage ?? "")
            }
            .environment(app)
            .task {
                app.loadConnections()
                #if DEBUG
                await app.runAutoConnectIfRequested()
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { app.flushForBackground() }
            }
            #if DEBUG && os(macOS)
            .background(PerfSpikeAutoOpener())
            #endif
        }
        #if DEBUG && os(macOS)
        Window("Perf Spike", id: "perf-spike") { PerfSpikeView() }
        #endif
    }
}
