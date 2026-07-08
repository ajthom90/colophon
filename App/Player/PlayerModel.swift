import Foundation
import ABSKit
import PlayerEngine

/// The full player's thin derivation layer over the shared `PlaybackController` (`AppState.playback`)
/// and the now-playing chapter list (`AppState.nowPlayingChapters`, set from the /play envelope).
///
/// It owns NO playback logic and NO independent mutable state — every value is derived live from
/// `playback` / `app.nowPlayingChapters` (so the SwiftUI views that read these properties observe
/// the underlying `@Observable` `PlaybackController`/`AppState` directly and update as playback
/// ticks), and every action delegates straight to the controller. Because it holds no persistent
/// state of its own, a view may freely recreate it each `body` evaluation; the scrubber's transient
/// drag state lives on the `FullPlayerView`, not here.
///
/// Chapters are GLOBAL book seconds (see the milestone's endpoint reference), so the scrubber and
/// chapter lookups all work directly in global time (`0...totalDuration`) — `BookTimeline` maps
/// global↔track internally inside `PlaybackController.seek(toGlobal:)`.
@Observable
@MainActor
final class PlayerModel {
    private let app: AppState

    init(app: AppState) { self.app = app }

    var playback: PlaybackController { app.playback }

    // MARK: - Derived playback values

    var currentTime: TimeInterval { playback.globalTime }
    var duration: TimeInterval { playback.totalDuration }
    var isPlaying: Bool { playback.isPlaying }
    var title: String { playback.title }
    var author: String { playback.author }
    var skipInterval: Int { playback.skipInterval }
    /// The book's current playback rate (e.g. `1.5`) — `SpeedControl`'s Menu reads this to show
    /// the current selection and highlight it among the options.
    var rate: Double { Double(playback.rate) }

    /// The now-playing chapters (global seconds), sorted by start — the source both the scrubber's
    /// current-chapter label and `ChapterListView` read.
    var chapters: [Chapter] { app.nowPlayingChapters.sorted { $0.start < $1.start } }

    /// Fraction 0...1 of the whole book elapsed — drives the scrubber's default position.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// The chapter containing the current global time (`start ≤ t < end`), or the nearest sensible
    /// one at the edges — see `chapter(at:in:)`.
    var currentChapter: Chapter? { Self.chapter(at: currentTime, in: chapters) }

    /// Index of `currentChapter` within `chapters` (start-sorted), for a "Chapter N of M" label.
    var currentChapterIndex: Int? {
        guard let current = currentChapter else { return nil }
        return chapters.firstIndex { $0.id == current.id }
    }

    /// h:mm:ss / m:ss elapsed string (pair with `.monospacedDigit()` at the call site).
    var elapsedString: String { Self.timeString(currentTime) }

    /// Signed "-h:mm:ss" remaining-in-book string (pair with `.monospacedDigit()`).
    var remainingString: String { "-" + Self.timeString(max(duration - currentTime, 0)) }

    // MARK: - Actions (pure delegation to the controller)

    func seek(toGlobal time: TimeInterval) { playback.seek(toGlobal: time) }
    func seekToChapter(_ chapter: Chapter) { playback.seek(toGlobal: chapter.start) }
    func togglePlayPause() { playback.togglePlayPause() }
    func skipForward() { playback.skip(Double(playback.skipInterval)) }
    func skipBackward() { playback.skip(-Double(playback.skipInterval)) }

    /// `SpeedControl`'s write path (Task 7) — routes through `AppState.setPlaybackRate`, which
    /// applies the rate live AND persists it as this book's per-book preference (Task 7's `v3`
    /// `cachedItemPref` table), rather than calling `playback.setRate` directly.
    func setRate(_ rate: Double) { app.setPlaybackRate(rate) }

    /// Seek to the next chapter's start (no-op if already in/at the last chapter). Drives the
    /// Mac `⌥⌘→` Next Chapter command.
    func goToNextChapter() {
        if let start = Self.nextChapterStart(after: currentTime, in: chapters) {
            playback.seek(toGlobal: start)
        }
    }

    /// Previous-chapter behavior (the Music/Podcasts idiom): if more than ~3s into the current
    /// chapter, restart it; otherwise jump to the previous chapter's start. Drives `⌥⌘←`.
    func goToPreviousChapter() {
        if let start = Self.previousChapterStart(before: currentTime, in: chapters) {
            playback.seek(toGlobal: start)
        }
    }

    // MARK: - Pure helpers (unit-tested in ColophonTests)

    /// The chapter a given global time falls in. Prefers a chapter that strictly contains `time`
    /// (`start ≤ time < end`); past the last chapter's end (e.g. `time == duration`) returns the
    /// last chapter; in a gap or before the first chapter returns the latest chapter that has
    /// already started, falling back to the first. Returns nil only for an empty chapter list.
    /// Order-independent (sorts by `start`) so it's correct regardless of the server's ordering.
    static func chapter(at time: TimeInterval, in chapters: [Chapter]) -> Chapter? {
        guard !chapters.isEmpty else { return nil }
        let sorted = chapters.sorted { $0.start < $1.start }
        if let containing = sorted.first(where: { time >= $0.start && time < $0.end }) {
            return containing
        }
        if let last = sorted.last, time >= last.end { return last }
        return sorted.last(where: { $0.start <= time }) ?? sorted.first
    }

    /// The start of the first chapter that begins after `time` (with a small epsilon so being
    /// exactly at a boundary advances rather than no-ops), or nil when `time` is in/at the last
    /// chapter. Order-independent (sorts by `start`). Drives Next Chapter.
    static func nextChapterStart(after time: TimeInterval, in chapters: [Chapter]) -> TimeInterval? {
        chapters.sorted { $0.start < $1.start }.first { $0.start > time + 0.5 }?.start
    }

    /// The Previous-Chapter target for `time`: restart the current chapter if more than 3s in,
    /// else the previous chapter's start (or the current/first chapter's start when already at the
    /// beginning). Order-independent. Returns nil only for an empty chapter list.
    static func previousChapterStart(before time: TimeInterval, in chapters: [Chapter]) -> TimeInterval? {
        let sorted = chapters.sorted { $0.start < $1.start }
        guard let currentIndex = sorted.lastIndex(where: { $0.start <= time }) else {
            return sorted.first?.start
        }
        let currentStart = sorted[currentIndex].start
        if time - currentStart > 3 { return currentStart }        // deep in the chapter → restart it
        if currentIndex > 0 { return sorted[currentIndex - 1].start } // near the top → previous chapter
        return currentStart                                        // already the first chapter
    }

    /// "h:mm:ss" when at least an hour, else "m:ss". Non-finite / non-positive input reads as 0:00.
    static func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
