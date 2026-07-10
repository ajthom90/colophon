import AppIntents

/// The app-side actions the Siri/Shortcuts intents (`ResumeIntent` / `SearchColophonIntent`, M2b
/// Task 5) reach in the RUNNING app via `@Dependency` — mirroring the playback intents'
/// `PlaybackControlProvider` bridge (`AudioPlaybackIntentBridge`). Registered ONCE at launch
/// (`ColophonApp.init`); because those intents `openAppWhenRun`, `perform()` runs in the app process,
/// where this provider (wrapping the live `AppState`) is registered — so the intent reaches the real
/// app state (resume the top continue-listening item / route to Search) rather than trapping on an
/// unregistered dependency. Holds a strong `AppState` ref (retained for the app's lifetime; no cycle
/// — `AppState` doesn't hold the provider).
@MainActor
final class AppActionProvider {
    private let app: AppState
    init(app: AppState) { self.app = app }

    func resumeTopContinueListening() async { await app.resumePlayback() }
    func presentSearch(query: String?) { app.requestSearch(query: query) }
}

enum AppIntentActionBridge {
    @MainActor
    static func register(app: AppState) {
        // `add(dependency:)` takes an `@autoclosure @escaping @Sendable` closure that runs in a
        // nonisolated context, so build the (MainActor) provider HERE and hand over the already-built
        // value (a `@MainActor` class is implicitly `Sendable`) — the same construction discipline
        // `AudioPlaybackIntentBridge` follows.
        let provider = AppActionProvider(app: app)
        AppDependencyManager.shared.add(dependency: provider)
    }
}
