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
    /// Single source of truth for typography (Global Constraints: `colophon.typeface`, "serif"
    /// default | "sans"). Applied outermost in the `WindowGroup` content's modifier chain, so it
    /// reaches every view in the tree — including content injected by later modifiers like
    /// `PlayerBarView`'s `safeAreaInset` — AND again on the macOS `Settings` scene below, since a
    /// `Settings` scene does not inherit modifiers from the `WindowGroup` scene. Per-view
    /// `.fontDesign(.serif)` modifiers were removed everywhere else in `App/Views/*`; do not
    /// reintroduce them.
    @AppStorage("colophon.typeface") private var typeface = "serif"

    init() {
        #if DEBUG && os(macOS)
        PerfSpikeClock.processLaunch = Date()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // Boot flow (unchanged): any stored connection → the `ConnectionsView` hub (which
                // auto-resumes the last-active one, cached-first, even with the server down);
                // otherwise the first-run `ConnectView`. Once a connection is active
                // (`phase == .connected`), the connected-phase content becomes the per-platform
                // `RootShell` — the native Liquid Glass navigation shell, which owns its own
                // now-playing transport (so the legacy global `PlayerBarView` inset is gone). The
                // shell exposes Connections/Settings via its account menu, and `ConnectionsView`
                // stays the not-yet-connected hub.
                if app.connections.isEmpty {
                    NavigationStack { ConnectView() }
                } else if app.phase == .connected {
                    RootShell()
                } else {
                    ConnectionsView()
                }
            }
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
            .fontDesign(typeface == "serif" ? .serif : .default)
        }
        #if os(macOS)
        // Mac keyboard transport: Space play/pause, ⌘←/⌘→ skip, speed submenu — wired to the same
        // `PlaybackController` the shell's `TransportBar` drives. Guarded on an active session.
        .commands { PlaybackCommands(app: app) }
        #endif
        #if DEBUG && os(macOS)
        Window("Perf Spike", id: "perf-spike") { PerfSpikeView() }
        #endif
        #if os(macOS)
        // iOS/iPadOS have no `Settings` scene (⌘, doesn't exist there); the same `SettingsView`
        // is reached from a gear button on `ConnectionsView` instead.
        //
        // `Settings` is a SEPARATE `Scene` from the `WindowGroup` above — it does NOT inherit the
        // `.fontDesign` applied to the WindowGroup's content, even though both scenes live in the
        // same `App` struct. So the same `@AppStorage("colophon.typeface")` key is applied again
        // here, directly on `SettingsView`. Two call sites, one key: correct for two scenes.
        Settings {
            SettingsView()
                .fontDesign(typeface == "serif" ? .serif : .default)
        }
        #endif
    }
}
