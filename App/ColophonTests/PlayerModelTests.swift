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
}
