import AppIntents
import ColophonShared

// The App Intents that control playback for the companion surfaces (M2b Task 3). They live in a
// SharedIntents source folder compiled into BOTH the app target and the ColophonWidgets extension so
// (a) the app's App Intents metadata includes them — the system routes `perform()` to the running app
// process — and (b) the Control Center control (in the extension) can reference `SetPlaybackIntent`.
//
// BRIDGE to the live player: each intent resolves `PlaybackControlProvider` via `@Dependency`. The app
// registers a provider wrapping the LIVE `PlaybackController` at launch (`AudioPlaybackIntentBridge`),
// so when the app is running — which a media app must be to hold audio — `perform()` reaches the real
// player. This is ADDITIVE to the existing `MPRemoteCommandCenter` now-playing controls
// (`NowPlayingUpdater`), which stay exactly as they were.
//
// The types are MainActor-isolated (the app + extension both default to `MainActor`), which is fine for
// App Intents; `perform()` therefore already runs on the MainActor to touch the MainActor-isolated
// provider. `static let title` (an immutable Sendable value) satisfies the protocol's nonisolated
// static requirement even on a MainActor type.

/// Sets the play/pause state — the `SetValueIntent` behind the Control Center / Lock Screen play-pause
/// toggle (`PlayPauseControlWidget`). `value` is the DESIRED playing state the toggle requests
/// (on = play), so the control's optimistic flip maps straight to play/pause on the live player.
struct SetPlaybackIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Play or pause the current audiobook.")

    @Parameter(title: "Playing") var value: Bool
    @Dependency var control: PlaybackControlProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        control.perform(value ? .play : .pause)
        return .result()
    }
}

/// Toggles play/pause regardless of current state — for Siri/Shortcuts and the Live Activity button
/// (Task 4). Same live-player `@Dependency` bridge as `SetPlaybackIntent`.
struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Play/Pause"
    static let description = IntentDescription("Toggle play or pause for the current audiobook.")

    @Dependency var control: PlaybackControlProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        control.perform(.togglePlayPause)
        return .result()
    }
}

/// Skips forward by the app's live skip interval.
struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward in the current audiobook.")

    @Dependency var control: PlaybackControlProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        control.perform(.skipForward)
        return .result()
    }
}

/// Skips back by the app's live skip interval.
struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Back"
    static let description = IntentDescription("Skip back in the current audiobook.")

    @Dependency var control: PlaybackControlProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        control.perform(.skipBackward)
        return .result()
    }
}
