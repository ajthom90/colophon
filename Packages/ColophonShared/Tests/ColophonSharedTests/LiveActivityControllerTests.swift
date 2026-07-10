import Testing
import Foundation
@testable import ColophonShared

/// A fake `ActivityManaging` that records the start/update/end calls `LiveActivityController` makes —
/// the seam the lifecycle DECISION logic is asserted against, with NO live ActivityKit host (a device).
/// `isActive` mirrors the real manager's contract: true after a start, false after an end.
@MainActor
private final class FakeActivityManager: ActivityManaging {
    var areActivitiesEnabled = true
    /// When false, `start` records the call but does NOT go active — models a real ActivityKit
    /// request that silently fails, so the record-gating retry can be asserted.
    var startSucceeds = true
    private(set) var isActive = false
    private(set) var starts: [LiveActivityState] = []
    private(set) var updates: [LiveActivityState] = []
    private(set) var endCount = 0

    func start(_ state: LiveActivityState) { starts.append(state); if startSucceeds { isActive = true } }
    func update(_ state: LiveActivityState) { updates.append(state) }
    func end() { endCount += 1; isActive = false }
}

/// A settable clock so the progress throttle is deterministically testable.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000)
}

/// Builds a `LiveActivityState`; overrides only what a test varies.
private func makeState(
    itemID: String = "book1",
    episodeID: String? = nil,
    chapterTitle: String? = "Chapter 1",
    progress: Double = 0.1,
    isPlaying: Bool = true,
    elapsed: TimeInterval = 10,
    artworkThumbnailPath: String? = nil
) -> LiveActivityState {
    LiveActivityState(
        itemID: itemID, episodeID: episodeID, title: "A Book", author: "An Author",
        chapterTitle: chapterTitle, progress: progress, isPlaying: isPlaying,
        elapsed: elapsed, artworkThumbnailPath: artworkThumbnailPath)
}

// MARK: - Start

@MainActor
@Test func startsOnPlayWhenActivitiesEnabled() {
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake)

    controller.sync(makeState())

    #expect(fake.starts.count == 1)
    #expect(fake.starts.first?.identity == "book1|")
    #expect(fake.isActive == true)
    #expect(fake.endCount == 0)
}

@MainActor
@Test func skipsStartCleanlyWhenActivitiesDisabled() {
    let fake = FakeActivityManager()
    fake.areActivitiesEnabled = false
    let controller = LiveActivityController(manager: fake)

    controller.sync(makeState())

    // Disabled → nothing started, nothing to leak; a later signal still can't start.
    #expect(fake.starts.isEmpty)
    #expect(fake.isActive == false)
    controller.sync(makeState(progress: 0.2))
    #expect(fake.starts.isEmpty)
    #expect(fake.updates.isEmpty)
}

// MARK: - Update (immediate on chapter / play-pause; throttled on progress)

@MainActor
@Test func updatesImmediatelyOnPlayPauseChange() {
    let clock = TestClock()
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake, progressThrottle: 15, now: { clock.now })

    controller.sync(makeState(isPlaying: true))
    // A pause one second later — well within the progress throttle, but play/pause is significant.
    clock.now += 1
    controller.sync(makeState(isPlaying: false))

    #expect(fake.updates.count == 1)
    #expect(fake.updates.first?.isPlaying == false)
}

@MainActor
@Test func updatesImmediatelyOnChapterChange() {
    let clock = TestClock()
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake, progressThrottle: 15, now: { clock.now })

    controller.sync(makeState(chapterTitle: "Chapter 1"))
    clock.now += 2   // within throttle, but a new chapter is significant
    controller.sync(makeState(chapterTitle: "Chapter 2"))

    #expect(fake.updates.count == 1)
    #expect(fake.updates.first?.chapterTitle == "Chapter 2")
}

@MainActor
@Test func throttlesProgressOnlyUpdates() {
    let clock = TestClock()
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake, progressThrottle: 15, now: { clock.now })

    controller.sync(makeState(progress: 0.10))          // start
    // A burst of progress-only ticks inside the throttle window → NO updates.
    clock.now += 3;  controller.sync(makeState(progress: 0.11))
    clock.now += 3;  controller.sync(makeState(progress: 0.12))
    clock.now += 3;  controller.sync(makeState(progress: 0.13))
    #expect(fake.updates.isEmpty)

    // Past the window → exactly one progress update lands.
    clock.now += 10;  controller.sync(makeState(progress: 0.20))   // 19s since start
    #expect(fake.updates.count == 1)
    #expect(fake.updates.first?.progress == 0.20)

    // And the window resets from that push.
    clock.now += 5;  controller.sync(makeState(progress: 0.21))
    #expect(fake.updates.count == 1)
}

// MARK: - End (stop / retire / sign-out publishes a nil clear)

@MainActor
@Test func endsWhenNothingIsPlaying() {
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake)

    controller.sync(makeState())
    #expect(fake.isActive == true)

    controller.sync(nil)   // retire / stop's authoritative clear
    #expect(fake.endCount == 1)
    #expect(fake.isActive == false)

    // Idempotent: a redundant clear (a connection switch after a stop) doesn't double-end or leak.
    controller.sync(nil)
    #expect(fake.endCount == 1)
}

// MARK: - Exactly one across a book switch / a connection switch

@MainActor
@Test func bookSwitchEndsOldAndStartsNewExactlyOne() {
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake)

    controller.sync(makeState(itemID: "book1"))
    // A DIFFERENT item while the first is still live (defensive path — no intervening nil clear).
    controller.sync(makeState(itemID: "book2"))

    #expect(fake.starts.count == 2)
    #expect(fake.starts.map(\.identity) == ["book1|", "book2|"])
    #expect(fake.endCount == 1)              // the old one was ended
    #expect(fake.isActive == true)           // exactly ONE remains
}

@MainActor
@Test func connectionSwitchEndsTheActivity() {
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake)

    controller.sync(makeState(itemID: "book1"))
    // A sign-out / connection removal that owned playback retires the session → publishes a nil clear.
    controller.sync(nil)

    #expect(fake.endCount == 1)
    #expect(fake.isActive == false)
    #expect(fake.starts.count == 1)          // no phantom restart
}

@MainActor
@Test func distinctEpisodeOfSamePodcastEndsOldAndStartsNew() {
    let fake = FakeActivityManager()
    let controller = LiveActivityController(manager: fake)

    controller.sync(makeState(itemID: "pod1", episodeID: "ep1", chapterTitle: nil, isPlaying: true))
    // Same podcast, DIFFERENT episode → a switch (identity includes the episode).
    controller.sync(makeState(itemID: "pod1", episodeID: "ep2", chapterTitle: nil, isPlaying: true))

    #expect(fake.starts.map(\.identity) == ["pod1|ep1", "pod1|ep2"])
    #expect(fake.endCount == 1)
    #expect(fake.isActive == true)
}

// MARK: - Record only a start the manager actually honored

@MainActor
@Test func retriesStartWhenManagerStartSilentlyNoOps() {
    let fake = FakeActivityManager()
    fake.startSucceeds = false   // model a failed ActivityKit request
    let controller = LiveActivityController(manager: fake)

    controller.sync(makeState())
    // The manager didn't go active, so the controller must NOT remember it as live…
    #expect(fake.starts.count == 1)
    #expect(fake.isActive == false)

    // …and the next signal retries the start (rather than treating it as an update).
    controller.sync(makeState(progress: 0.2))
    #expect(fake.starts.count == 2)
    #expect(fake.updates.isEmpty)

    // Once the manager does go active, it starts once more and settles (no further retry).
    fake.startSucceeds = true
    controller.sync(makeState(progress: 0.3))
    #expect(fake.starts.count == 3)
    #expect(fake.isActive == true)
}
