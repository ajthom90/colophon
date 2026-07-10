import Testing
import AppIntents
import ColophonShared
@testable import Colophon

/// A fake `PlaybackCommanding` recording what the intents drive — the "fake player" the intent
/// `perform()` paths are asserted against, with NO live intent host.
@MainActor
private final class FakeIntentPlayer: PlaybackCommanding {
    var isPlaying = false
    var skipInterval = 30
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var toggleCount = 0
    private(set) var skips: [Double] = []

    func play() { playCount += 1; isPlaying = true }
    func pause() { pauseCount += 1; isPlaying = false }
    func togglePlayPause() { toggleCount += 1; isPlaying.toggle() }
    func skip(_ seconds: Double) { skips.append(seconds) }
}

/// Exercises the App Intents' `perform()` end to end through the `@Dependency` bridge: `@Dependency`
/// is only auto-populated inside the system's real perform flow, so a direct-call test injects the
/// provider by SETTING the intent's dependency property first (the supported "manually set prior to
/// access" path) — the same `PlaybackControlProvider` the production `AudioPlaybackIntentBridge`
/// registers, wrapping a fake player instead of the live `PlaybackController`. This proves the intent
/// → player effect without a live intent host or a real audio session.
@MainActor
struct AudioPlaybackIntentTests {
    /// The Control Center toggle's `SetValueIntent`: `value` is the desired playing state, so
    /// `value = true` plays and `value = false` pauses the injected player.
    @Test func setPlaybackIntentPlaysAndPausesByValue() async throws {
        let fake = FakeIntentPlayer()
        let provider = PlaybackControlProvider(handler: fake)

        let playIntent = SetPlaybackIntent()
        playIntent.control = provider
        playIntent.value = true
        _ = try await playIntent.perform()
        #expect(fake.playCount == 1)
        #expect(fake.isPlaying == true)

        let pauseIntent = SetPlaybackIntent()
        pauseIntent.control = provider
        pauseIntent.value = false
        _ = try await pauseIntent.perform()
        #expect(fake.pauseCount == 1)
        #expect(fake.isPlaying == false)
    }

    @Test func togglePlaybackIntentFlipsThePlayer() async throws {
        let fake = FakeIntentPlayer()
        let provider = PlaybackControlProvider(handler: fake)

        let intent = TogglePlaybackIntent()
        intent.control = provider

        _ = try await intent.perform()
        #expect(fake.toggleCount == 1)
        #expect(fake.isPlaying == true)

        _ = try await intent.perform()
        #expect(fake.toggleCount == 2)
        #expect(fake.isPlaying == false)
    }

    /// Regression guard for the Critical review finding: all four intents MUST conform to
    /// `AppIntents.AudioPlaybackIntent` so the OS routes `perform()` to the app process (where the live
    /// provider is registered) rather than the widget extension (where only the no-op is). This binds
    /// each to `any AudioPlaybackIntent` — it fails to COMPILE if a conformance is dropped.
    @Test func intentsConformToAudioPlaybackIntent() {
        let intents: [any AudioPlaybackIntent] = [
            SetPlaybackIntent(), TogglePlaybackIntent(), SkipForwardIntent(), SkipBackwardIntent(),
        ]
        #expect(intents.count == 4)
    }

    @Test func skipIntentsUseTheLiveSkipInterval() async throws {
        let fake = FakeIntentPlayer()
        fake.skipInterval = 15
        let provider = PlaybackControlProvider(handler: fake)

        let forward = SkipForwardIntent()
        forward.control = provider
        _ = try await forward.perform()

        let backward = SkipBackwardIntent()
        backward.control = provider
        _ = try await backward.perform()

        #expect(fake.skips == [15, -15])
    }
}
