import Testing
import Foundation
import ABSKit
@testable import Colophon

/// Pure-logic proof for `PlayerModel`'s chapter derivation and time formatting — the parts with
/// non-trivial branching (containment vs. gap vs. past-the-end lookup, h:mm:ss vs m:ss). Both are
/// `static` and take plain values, so they're exercised without a `PlaybackController`/backend.
///
/// `ABSKit.Chapter`'s memberwise initializer is `internal` to ABSKit, so fixtures are built by
/// decoding the wire JSON (Chapter is `Decodable`) rather than calling an initializer.
@MainActor
struct PlayerModelTests {
    private func chapter(_ id: Int, _ start: Double, _ end: Double, _ title: String) -> Chapter {
        let json = #"{"id":\#(id),"start":\#(start),"end":\#(end),"title":"\#(title)"}"#
        return try! JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
    }

    /// A 3-chapter book with a deliberate GAP between chapter 2's end (250) and chapter 3's
    /// start (260), to exercise the gap-fallback branch.
    private var chapters: [Chapter] {
        [chapter(0, 0, 100, "One"),
         chapter(1, 100, 250, "Two"),
         chapter(2, 260, 400, "Three")]
    }

    @Test func emptyChaptersYieldNoCurrent() {
        #expect(PlayerModel.chapter(at: 42, in: []) == nil)
    }

    @Test func timeInsideAChapterReturnsThatChapter() {
        #expect(PlayerModel.chapter(at: 0, in: chapters)?.id == 0)
        #expect(PlayerModel.chapter(at: 99, in: chapters)?.id == 0)
        #expect(PlayerModel.chapter(at: 150, in: chapters)?.id == 1)
        #expect(PlayerModel.chapter(at: 399, in: chapters)?.id == 2)
    }

    @Test func chapterBoundaryIsHalfOpenStartInclusive() {
        // start ≤ t < end: the boundary time belongs to the chapter it STARTS.
        #expect(PlayerModel.chapter(at: 100, in: chapters)?.id == 1)
        #expect(PlayerModel.chapter(at: 260, in: chapters)?.id == 2)
    }

    @Test func timeInAGapFallsToTheLatestStartedChapter() {
        // 255 is past chapter 1's end (250) but before chapter 2's start (260).
        #expect(PlayerModel.chapter(at: 255, in: chapters)?.id == 1)
    }

    @Test func timeAtOrPastTheEndReturnsTheLastChapter() {
        #expect(PlayerModel.chapter(at: 400, in: chapters)?.id == 2)
        #expect(PlayerModel.chapter(at: 100_000, in: chapters)?.id == 2)
    }

    @Test func lookupIsOrderIndependent() {
        let shuffled = [chapters[2], chapters[0], chapters[1]]
        #expect(PlayerModel.chapter(at: 150, in: shuffled)?.id == 1)
    }

    @Test func timeStringFormatsBelowAnHourAsMinutesSeconds() {
        #expect(PlayerModel.timeString(0) == "0:00")
        #expect(PlayerModel.timeString(-5) == "0:00")
        #expect(PlayerModel.timeString(65) == "1:05")
        #expect(PlayerModel.timeString(599) == "9:59")
    }

    @Test func timeStringFormatsAnHourOrMoreAsHoursMinutesSeconds() {
        #expect(PlayerModel.timeString(3661) == "1:01:01")
        #expect(PlayerModel.timeString(7200) == "2:00:00")
    }

    // MARK: - Chapter navigation (Task 4 — Mac ⌥⌘←/⌥⌘→ commands)

    @Test func nextChapterStartAdvancesToTheFollowingChapter() {
        // Mid-chapter-0 → chapter 1 (start 100); mid-chapter-1 → chapter 2 (start 260).
        #expect(PlayerModel.nextChapterStart(after: 50, in: chapters) == 100)
        #expect(PlayerModel.nextChapterStart(after: 150, in: chapters) == 260)
    }

    @Test func nextChapterStartAtABoundaryAdvancesPastIt() {
        // Exactly at chapter 1's start (100): the +0.5 epsilon means we advance to chapter 2, not
        // no-op on the chapter we're already at the top of.
        #expect(PlayerModel.nextChapterStart(after: 100, in: chapters) == 260)
    }

    @Test func nextChapterStartInTheLastChapterIsNil() {
        #expect(PlayerModel.nextChapterStart(after: 300, in: chapters) == nil)
        #expect(PlayerModel.nextChapterStart(after: 400, in: chapters) == nil)
    }

    @Test func nextChapterStartEmptyIsNil() {
        #expect(PlayerModel.nextChapterStart(after: 10, in: []) == nil)
    }

    @Test func previousChapterStartDeepInChapterRestartsIt() {
        // 50s into chapter 0 (start 0) → restart chapter 0.
        #expect(PlayerModel.previousChapterStart(before: 50, in: chapters) == 0)
        // 60s into chapter 1 (start 100, time 160) → restart chapter 1.
        #expect(PlayerModel.previousChapterStart(before: 160, in: chapters) == 100)
    }

    @Test func previousChapterStartNearTopGoesToPreviousChapter() {
        // 2s into chapter 1 (start 100, time 102 — within the 3s threshold) → previous chapter (0).
        #expect(PlayerModel.previousChapterStart(before: 102, in: chapters) == 0)
        // 1s into chapter 2 (start 260, time 261) → previous chapter (1, start 100).
        #expect(PlayerModel.previousChapterStart(before: 261, in: chapters) == 100)
    }

    @Test func previousChapterStartNearTopOfFirstChapterStaysAtZero() {
        // 1s into chapter 0: no earlier chapter, so stay at its start.
        #expect(PlayerModel.previousChapterStart(before: 1, in: chapters) == 0)
    }

    @Test func previousChapterStartEmptyIsNil() {
        #expect(PlayerModel.previousChapterStart(before: 50, in: []) == nil)
    }

    @Test func chapterNavigationIsOrderIndependent() {
        let shuffled = [chapters[2], chapters[0], chapters[1]]
        #expect(PlayerModel.nextChapterStart(after: 50, in: shuffled) == 100)
        #expect(PlayerModel.previousChapterStart(before: 261, in: shuffled) == 100)
    }
}
