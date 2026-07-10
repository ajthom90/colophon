import Testing
@testable import ColophonShared

/// A fake `PlaybackCommanding` that records the calls `applyPlaybackCommand` makes — the "fake player"
/// the command → player mapping is asserted against, with no live player / audio session / intent host.
@MainActor
private final class FakePlaybackHandler: PlaybackCommanding {
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

// MARK: - applyPlaybackCommand → player mapping

@MainActor
@Test func applyPlayAndPauseCommandsReachThePlayer() {
    let handler = FakePlaybackHandler()

    applyPlaybackCommand(.play, to: handler)
    #expect(handler.playCount == 1)
    #expect(handler.isPlaying == true)

    applyPlaybackCommand(.pause, to: handler)
    #expect(handler.pauseCount == 1)
    #expect(handler.isPlaying == false)
}

@MainActor
@Test func applyTogglePlayPauseFlipsThePlayer() {
    let handler = FakePlaybackHandler()

    applyPlaybackCommand(.togglePlayPause, to: handler)
    #expect(handler.toggleCount == 1)
    #expect(handler.isPlaying == true)

    applyPlaybackCommand(.togglePlayPause, to: handler)
    #expect(handler.toggleCount == 2)
    #expect(handler.isPlaying == false)
}

@MainActor
@Test func applySkipCommandsUseTheLiveSkipInterval() {
    let handler = FakePlaybackHandler()
    handler.skipInterval = 45   // a non-default interval, read LIVE by the mapping

    applyPlaybackCommand(.skipForward, to: handler)
    applyPlaybackCommand(.skipBackward, to: handler)

    #expect(handler.skips == [45, -45])
}

// MARK: - PlaybackControlProvider (the @Dependency wrapper the intents call through)

@MainActor
@Test func providerForwardsCommandsAndReflectsIsPlaying() {
    let handler = FakePlaybackHandler()
    let provider = PlaybackControlProvider(handler: handler)

    #expect(provider.isPlaying == false)
    provider.perform(.play)
    #expect(handler.playCount == 1)
    #expect(provider.isPlaying == true)

    provider.perform(.togglePlayPause)
    #expect(handler.toggleCount == 1)
    #expect(provider.isPlaying == false)
}
