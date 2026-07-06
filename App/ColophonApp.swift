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

    var body: some Scene {
        WindowGroup {
            Group {
                if app.phase == .connected {
                    NavigationStack { LibrariesView() }
                        .safeAreaInset(edge: .bottom) { PlayerBarView() }
                        .alert("Playback error", isPresented: Binding(
                            get: { app.errorMessage != nil },
                            set: { if !$0 { app.errorMessage = nil } })
                        ) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(app.errorMessage ?? "")
                        }
                } else {
                    NavigationStack { ConnectView() }
                }
            }
            .environment(app)
            .task {
                #if DEBUG
                await app.runAutoConnectIfRequested()
                #endif
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
