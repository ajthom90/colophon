import Foundation
import Testing
import ABSKit
import MediaPlayer
@testable import PlayerEngine

/// Chapters {0–10},{10–25},{25–30} in GLOBAL seconds — the boundary fixture shared by both tests.
@MainActor
private func decodeChapters() -> [Chapter] {
    let json = """
    [{"id":1,"start":0,"end":10,"title":"One"},
     {"id":2,"start":10,"end":25,"title":"Two"},
     {"id":3,"start":25,"end":30,"title":"Three"}]
    """
    return try! JSONDecoder().decode([Chapter].self, from: Data(json.utf8))
}

/// A loaded + playing controller over a 30s book with the three chapters above and matching tracks
/// ([0,10),[10,25),[25,30) — same track shape as `PlaybackControllerTests.makeSession`).
@MainActor
private func makeChapteredController() -> (PlaybackController, FakePlayerBackend) {
    let json = """
    {"id":"ses_c","libraryItemId":"li_c","displayTitle":"Book","displayAuthor":"Auth",
     "duration":30,"startTime":0,"currentTime":0,"playMethod":0,
     "chapters":[{"id":1,"start":0,"end":10,"title":"One"},
                 {"id":2,"start":10,"end":25,"title":"Two"},
                 {"id":3,"start":25,"end":30,"title":"Three"}],
     "audioTracks":[{"index":1,"startOffset":0,"duration":10},
                    {"index":2,"startOffset":10,"duration":15},
                    {"index":3,"startOffset":25,"duration":5}]}
    """
    let session = try! JSONDecoder().decode(PlaybackSession.self, from: Data(json.utf8))
    let backend = FakePlayerBackend()
    let controller = PlaybackController(backend: backend)
    controller.load(session: session, trackURLs: [
        URL(string: "https://t/1")!, URL(string: "https://t/2")!, URL(string: "https://t/3")!,
    ])
    controller.play()
    return (controller, backend)
}

@MainActor @Suite struct NowPlayingUpdaterTests {
    /// The pure chapter-index lookup is boundary-correct: a chapter's `start` belongs to THAT
    /// chapter (`start ≤ time`), before the first chapter maps to the first, past the last maps to
    /// the last, and an empty chapter list is `nil` (a chapterless book).
    @Test func chapterIndexBoundaries() {
        let chapters = decodeChapters()
        #expect(NowPlayingUpdater.chapterIndex(at: -1, in: chapters) == 0)
        #expect(NowPlayingUpdater.chapterIndex(at: 0, in: chapters) == 0)
        #expect(NowPlayingUpdater.chapterIndex(at: 9.999, in: chapters) == 0)
        #expect(NowPlayingUpdater.chapterIndex(at: 10, in: chapters) == 1)
        #expect(NowPlayingUpdater.chapterIndex(at: 24.999, in: chapters) == 1)
        #expect(NowPlayingUpdater.chapterIndex(at: 25, in: chapters) == 2)
        #expect(NowPlayingUpdater.chapterIndex(at: 30, in: chapters) == 2)
        #expect(NowPlayingUpdater.chapterIndex(at: 5, in: []) == nil)
    }

    /// A book playing straight across a chapter boundary (only `tick()`s, no discrete action)
    /// refreshes the now-playing chapter EXACTLY ONCE per boundary — not every tick, and not never.
    /// Guards the "lock-screen chapter frozen at chapter 1" regression.
    @Test func tickAcrossChapterBoundaryRefreshesExactlyOnce() {
        let (controller, backend) = makeChapteredController()
        // configure()/play() established the starting chapter (0); no tick-driven refresh yet.
        #expect(controller.nowPlaying.chapterRefreshCount == 0)

        backend.moveTo(index: 0, offset: 5)   // global 5, still chapter 0 → tick, no refresh
        #expect(controller.nowPlaying.chapterRefreshCount == 0)

        backend.moveTo(index: 1, offset: 2)   // global 12, crossed into chapter 1 → one refresh
        #expect(controller.nowPlaying.chapterRefreshCount == 1)

        backend.moveTo(index: 1, offset: 6)   // global 16, still chapter 1 → no new refresh
        #expect(controller.nowPlaying.chapterRefreshCount == 1)

        backend.moveTo(index: 2, offset: 1)   // global 26, crossed into chapter 2 → second refresh
        #expect(controller.nowPlaying.chapterRefreshCount == 2)
    }

    /// Retiring the session (`unload`) tears down the now-playing surface, so the Lock Screen /
    /// Control Center / Now Playing menu stop showing the retired book and its remote commands stop
    /// driving the dead controller. Asserted via the `clearCount` seam (unit-testing the shared
    /// `MPNowPlayingInfoCenter` singleton directly is flaky); device-verification is in the checklist.
    @Test func unloadClearsNowPlaying() {
        let (controller, _) = makeChapteredController()
        #expect(controller.nowPlaying.clearCount == 0)
        controller.unload()
        #expect(controller.nowPlaying.clearCount == 1)
        #expect(controller.isPlaying == false)
    }

    /// `configure()` wires the hardware media keys' previous/next-TRACK remote commands (Mac F7/F9,
    /// BT/CarPlay remotes) — enabling them so the OS routes the keys to this app — and `clear()`
    /// (session retired) disables them again. Self-contained (establishes both states in-test) so it
    /// stays order-independent despite the shared `MPRemoteCommandCenter` singleton; the actual
    /// skip-by-interval behaviour of the handlers is device-verified (remote-command targets can't be
    /// fired via public API), while `isEnabled` is the unit-observable proxy for "the wiring is present".
    @Test func mediaKeysWirePreviousAndNextTrack() {
        let (controller, _) = makeChapteredController()   // load() → configure() ran
        let center = MPRemoteCommandCenter.shared()
        #expect(center.previousTrackCommand.isEnabled)
        #expect(center.nextTrackCommand.isEnabled)

        controller.unload()                               // → clear()
        #expect(center.previousTrackCommand.isEnabled == false)
        #expect(center.nextTrackCommand.isEnabled == false)
    }
}
