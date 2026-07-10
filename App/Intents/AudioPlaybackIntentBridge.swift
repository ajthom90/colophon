import AppIntents
import ColophonShared
import PlayerEngine

// The APP-ONLY half of the intent → live-player bridge (M2b Task 3). Lives in the app target (not the
// SharedIntents folder) because it references `PlayerEngine.PlaybackController`, which the widget
// extension doesn't link.

/// Conforms the app's LIVE `PlaybackController` to `PlaybackCommanding` — the retroactive, empty-body
/// bridge that lets an App Intent resolved in the running-app process drive the real player. The
/// controller already has every member (`isPlaying`, `skipInterval`, `play`/`pause`/`togglePlayPause`/
/// `skip`); this conformance just names them as the command surface. `@retroactive` because the type
/// (PlayerEngine) and the protocol (ColophonShared) are declared in other modules.
extension PlaybackController: @retroactive PlaybackCommanding {}

/// Registers the running app's playback as the App Intents `@Dependency` the playback intents
/// (`SetPlaybackIntent` / `TogglePlaybackIntent` / `SkipForwardIntent` / `SkipBackwardIntent`) resolve.
/// Called ONCE at app launch (`ColophonApp.init`) so that when the system runs a playback intent in the
/// app process — the case that matters, since a media app must be running to hold audio — `@Dependency`
/// resolves this live provider and the command reaches the real `PlaybackController`.
///
/// App-not-running limitation (documented, acceptable): with nothing playing there's no audio to
/// control. If the system needs to run an intent while the app is terminated it launches the app first
/// (running `ColophonApp.init` → this registration) before performing; a freshly launched controller
/// with no loaded session simply no-ops. The widget extension registers a `NoOpPlaybackCommanding`
/// fallback so an intent that (rarely) performs in the extension process resolves to an inert handler
/// rather than trapping. This whole surface is ADDITIVE: the `MPRemoteCommandCenter` lock-screen /
/// CarPlay media controls (`NowPlayingUpdater`) are untouched.
enum AudioPlaybackIntentBridge {
    @MainActor
    static func register(playback: PlaybackController) {
        // `add(dependency:)` takes an `@autoclosure @escaping @Sendable` closure that runs in a
        // nonisolated context, so build the (MainActor) provider HERE and hand the closure the
        // already-constructed value (a `@MainActor` class is implicitly `Sendable`).
        let provider = PlaybackControlProvider(handler: playback)
        AppDependencyManager.shared.add(dependency: provider)
    }
}
