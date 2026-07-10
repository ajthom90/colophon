import Testing
import Foundation
import AppIntents
import ABSKit
import ABSKitTestSupport
@testable import Colophon

/// Exercises the Siri/Shortcuts intents' `perform()` through the `@Dependency` `AppActionProvider`
/// bridge — the same "manually set the dependency prior to access" path `AudioPlaybackIntentTests`
/// uses (`@Dependency` is only auto-populated in the system's real perform flow). Wraps a bare
/// `AppState` and asserts the observable effect (the same one the shells consume).
@MainActor
struct SiriIntentsTests {
    private func makeApp() -> AppState {
        AppState(
            transportProvider: { MockTransport() },
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            socketFactory: { _, _ in FakeSocket() },
            tokenStore: InMemoryTokenStore(),
            downloadManagerProvider: { FakeDownloadManaging() })
    }

    /// "Search Colophon dune" → routes to Search with the seeded query (via `AppState.requestSearch`).
    @Test func searchIntentRoutesToSearchWithQuery() async throws {
        let app = makeApp()
        let intent = SearchColophonIntent()
        intent.actions = AppActionProvider(app: app)
        intent.query = "dune"

        _ = try await intent.perform()

        #expect(app.pendingSearchQuery == "dune")
        #expect(app.pendingNavigation == .search(query: "dune"))
    }

    /// "Resume my audiobook" reaches `AppState.resumePlayback`. With nothing loaded and an empty
    /// shelf it's a clean no-op (no session, no crash) — proving the intent → app-state path runs.
    @Test func resumeIntentReachesResumePlayback() async throws {
        let app = makeApp()
        let intent = ResumeIntent()
        intent.actions = AppActionProvider(app: app)

        _ = try await intent.perform()

        #expect(app.nowPlayingItemID == nil)
    }

    /// The three Siri intents are instantiable for `AppShortcutsProvider` registration (a compile +
    /// construct guard — note: NOT accessing `@Dependency var actions`, whose getter traps until the
    /// system's perform flow populates it).
    @Test func shortcutIntentsConstruct() {
        _ = ResumeIntent()
        _ = OpenColophonIntent()
        _ = SearchColophonIntent()
        #expect(Bool(true))
    }
}
