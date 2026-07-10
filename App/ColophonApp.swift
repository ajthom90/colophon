import SwiftUI
import CoreSpotlight

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
    @State private var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    /// Single source of truth for typography (Global Constraints: `colophon.typeface`, "serif"
    /// default | "sans"). Applied outermost in the `WindowGroup` content's modifier chain, so it
    /// reaches every view in the tree — including content injected by later modifiers like the
    /// shell's `TransportBar` `safeAreaInset` — AND again on the macOS `Settings` scene below, since a
    /// `Settings` scene does not inherit modifiers from the `WindowGroup` scene. Per-view
    /// `.fontDesign(.serif)` modifiers were removed everywhere else in `App/Views/*`; do not
    /// reintroduce them.
    @AppStorage("colophon.typeface") private var typeface = "serif"
    /// The Settings skip-interval (Task 4). Read here — the one always-mounted scene content that
    /// holds `app` — so changing it applies to `playback.skipInterval` LIVE for the current
    /// session (the transport glyph + jump reflect it immediately), not just on the next book.
    /// `@AppStorage` is UserDefaults-KVO-backed, so a change from ANY scene (the account-menu sheet
    /// on iOS, the ⌘, `Settings` scene on Mac) fires the `onChange` below.
    @AppStorage("colophon.skipInterval") private var skipInterval = AppState.defaultSkipInterval

    init() {
        // Wire the real ActivityKit-backed now-playing Live Activity manager (M2b Task 4) here — the
        // app entry point — rather than in `AppState.init`, so unit tests (which build `AppState`
        // directly) never touch ActivityKit in the test host. iOS-only: Live Activities are iOS-only.
        #if os(iOS)
        let appState = AppState(liveActivityManager: LiveActivityManager())
        #else
        let appState = AppState()
        #endif
        _app = State(initialValue: appState)
        // Register the App Intents dependency at app launch (M2b Task 3): the playback intents
        // (`SetPlaybackIntent`/`TogglePlaybackIntent`/`SkipForward/BackwardIntent`) resolve this LIVE
        // provider via `@Dependency`, so when the system runs a playback intent in the app process
        // (the Control Center toggle, a Siri phrase, a Live Activity button) it reaches the real
        // `PlaybackController`. Done in `init` — not a scene `.task` — so a background app-launch to
        // service an intent (no scene rendered) still registers it before `perform()` runs.
        AudioPlaybackIntentBridge.register(playback: appState.playback)
        // Register the Siri/Shortcuts action dependency (M2b Task 5): `ResumeIntent`/
        // `SearchColophonIntent` resolve this `AppActionProvider` (wrapping the live `AppState`) via
        // `@Dependency`. Registered in `init` — like the playback bridge above — so a cold launch to
        // service a Siri phrase has it before `perform()` runs.
        AppIntentActionBridge.register(app: appState)
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
            // M2b Task 5: the widget / Live Activity / Control-Center deep links FINALLY LAND here.
            // `colophon://item/<id>` (+ optional `?episode=`) → push the item/podcast/episode detail;
            // `colophon://resume` → resume the top continue-listening item. `handleDeepLink` parses +
            // dispatches through the pure `DeepLinkRouter`; a non-`colophon` / unrecognized URL (e.g. an
            // OAuth callback) is silently ignored.
            .onOpenURL { app.handleDeepLink($0) }
            // A Spotlight result tap hands back an `NSUserActivity` whose identifier is the indexed
            // item's `connectionID/itemID` — route it to the item detail (active connection only).
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                    app.handleSpotlightActivity(uniqueIdentifier: id)
                }
            }
            .task {
                app.loadConnections()
                // Start the continuous NWPathMonitor reachability signal (M2a Task 6): its
                // OFFLINE→ONLINE link edge triggers the reconnect reconcile (offline local sessions
                // → server). Idempotent; safe to call on every WindowGroup task re-entry.
                app.startReachabilityMonitoring()
                #if DEBUG
                await app.runAutoConnectIfRequested()
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    app.flushForBackground()
                } else if phase == .active, app.activeConnectionID != nil {
                    // Backgrounding a live connection for a while (podcast switch, phone lock,
                    // Mac App Switcher) and coming back must not leave Home's progress pill
                    // showing a stale percentage until the user happens to pull-to-refresh —
                    // this is the same `me()` join HomeView runs on appear, just re-armed on
                    // foreground. Guarded on `activeConnectionID` so it's a no-op at first
                    // launch (no connection yet) and while disconnected/switching; cheap single
                    // request, no full shelves refetch.
                    Task { await app.refreshProgress() }
                }
            }
            #if DEBUG && os(macOS)
            .background(PerfSpikeAutoOpener())
            #endif
            .onChange(of: skipInterval) { _, newValue in
                // Live-apply the Settings change to the running session's transport (glyph + jump)…
                app.playback.skipInterval = newValue
                // …and re-advertise it to the lock-screen / Control-Center / media-key remote
                // commands so their skip buttons reflect the new interval mid-session (Task 9
                // follow-up A). `NowPlayingUpdater.configure` only advertised `preferredIntervals`
                // at `load()`; this re-pushes them without reloading the book.
                app.playback.refreshRemoteSkipInterval()
            }
            .fontDesign(typeface == "serif" ? .serif : .default)
        }
        #if os(macOS)
        // Mac keyboard transport: play/pause (menu-only, NO bare Space — the M1c-a fix), ⌘←/⌘→
        // skip, ⌥⌘←/⌥⌘→ prev/next chapter, ⇧⌘,/⇧⌘. speed steppers + submenu — wired to the same
        // `PlaybackController` the shell's `TransportBar` drives. Guarded on an active session.
        .commands { PlaybackCommands(app: app) }
        #endif
        #if os(macOS)
        // The dedicated Mac full-player Window (Task 4's per-platform presentation — a real window,
        // NOT an iOS-style full-window sheet takeover). Opened from `TransportBar`'s expand
        // affordance via `openWindow(id: PlayerWindowScene.id)`; a single instance (`Window`, not
        // `WindowGroup`). It's a SEPARATE scene, so — like the `Settings` scene below — it inherits
        // neither `app` nor the root `.fontDesign`, and re-applies both here.
        Window("Now Playing", id: PlayerWindowScene.id) {
            FullPlayerView()
                .environment(app)
                .fontDesign(typeface == "serif" ? .serif : .default)
                .frame(minWidth: 380, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 440, height: 720)
        // Don't let macOS state-restoration reopen an empty player window on launch — it only ever
        // opens on demand from the transport's expand affordance.
        .restorationBehavior(.disabled)
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
        // here, directly on the `NavigationStack` wrapping `SettingsView`. Multiple call sites,
        // one key: correct for every scene.
        //
        // M2c Task 2: wrapped in a `NavigationStack` (it wasn't before) — `SettingsView` gained a
        // `NavigationLink` to `TipJarView`, and without a `NavigationStack` ancestor here that link
        // would dead-end on macOS (this project's navigationDestination-placement gotcha: a
        // `NavigationLink` needs a `NavigationStack` to push into). The two other `SettingsView`
        // call sites (`RootShell`'s account-menu sheet, `ConnectionsView`'s iOS sheet) already
        // provide their own `NavigationStack`, so only this scene needed the change.
        Settings {
            NavigationStack {
                SettingsView()
            }
            .fontDesign(typeface == "serif" ? .serif : .default)
        }
        #endif
    }
}
