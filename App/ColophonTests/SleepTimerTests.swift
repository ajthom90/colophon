import Testing
import Foundation
import ABSKit
@testable import Colophon

/// Fire-logic proof for `SleepTimer` (Task 5) — the deliverable's guarantee that arming, counting,
/// extending, cancelling, and firing all behave, driven by an INJECTED clock and a trivial fake
/// host so there are NO real sleeps and no AVFoundation. (The real volume-ramp + pause ordering is
/// proven separately by PlayerEngine's `fadeRampReachesZeroThenPauses`.)
@MainActor
struct SleepTimerTests {

    /// A controllable clock (mirrors the engine tests' `ClockBox`).
    final class Clock: @unchecked Sendable {
        private var value: Date
        init(_ start: Date) { value = start }
        var now: Date { value }
        func advance(_ seconds: TimeInterval) { value = value.addingTimeInterval(seconds) }
    }

    /// Minimal `SleepTimerHost` fake: records the fade call and models pause by flipping
    /// `isPlaying`; `globalTime` is settable to drive End-of-Chapter.
    final class FakeHost: SleepTimerHost {
        var isPlaying = true
        var globalTime: TimeInterval = 0
        private(set) var fadeCalled = false
        private(set) var fadeDuration: TimeInterval?
        func fadeOutAndPause(over duration: TimeInterval) {
            fadeCalled = true
            fadeDuration = duration
            isPlaying = false
        }
    }

    /// `ABSKit.Chapter`'s memberwise init is internal to ABSKit — build fixtures by decoding JSON.
    private func chapter(_ id: Int, _ start: Double, _ end: Double) -> Chapter {
        let json = #"{"id":\#(id),"start":\#(start),"end":\#(end),"title":"C\#(id)"}"#
        return try! JSONDecoder().decode(Chapter.self, from: Data(json.utf8))
    }

    private func makeTimer(host: FakeHost, clock: Clock) -> SleepTimer {
        // autoTick: false — the test is the only thing that calls `tick()` (deterministic).
        SleepTimer(host: host, now: { clock.now }, fadeDuration: 5, autoTick: false)
    }

    // MARK: - The five required tests

    @Test func sleepTimerFiresAtDeadlineAndPauses() {
        let host = FakeHost()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let timer = makeTimer(host: host, clock: clock)

        timer.arm(.preset(minutes: 30))
        #expect(timer.remaining == 1800)
        #expect(host.fadeCalled == false)

        clock.advance(30 * 60)   // reach the deadline
        timer.tick()

        #expect(host.fadeCalled == true)
        #expect(host.fadeDuration == 5)
        #expect(host.isPlaying == false)   // the fade paused playback
        #expect(timer.isArmed == false)    // disarmed after firing
        #expect(timer.remaining == nil)
    }

    @Test func endOfChapterComputesCurrentChapterEnd() {
        // Chapters: [0,100), [100,250), [260,400). Mid-chapter-2 (id 1) at t=150 → fire at 250.
        let chapters = [chapter(0, 0, 100), chapter(1, 100, 250), chapter(2, 260, 400)]
        #expect(SleepTimer.endOfChapterFireTime(chapters: chapters, at: 150) == 250)
        #expect(SleepTimer.endOfChapterFireTime(chapters: chapters, at: 0) == 100)
        #expect(SleepTimer.endOfChapterFireTime(chapters: chapters, at: 300) == 400)
        #expect(SleepTimer.endOfChapterFireTime(chapters: [], at: 10) == nil)

        // And the armed timer fires when playback reaches that boundary.
        let host = FakeHost()
        host.globalTime = 150
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let timer = makeTimer(host: host, clock: clock)
        timer.chapters = chapters
        timer.arm(.endOfChapter)
        #expect(timer.remaining == 100)    // 250 - 150

        host.globalTime = 200
        timer.tick()
        #expect(host.fadeCalled == false)  // not yet at the boundary
        #expect(timer.remaining == 50)

        host.globalTime = 250
        timer.tick()
        #expect(host.fadeCalled == true)   // reached chapter 2's end
        #expect(host.isPlaying == false)
    }

    @Test func cancelBeforeDeadlineDoesNotPause() {
        let host = FakeHost()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let timer = makeTimer(host: host, clock: clock)

        timer.arm(.preset(minutes: 30))
        timer.turnOff()

        clock.advance(60 * 60)   // well past the (cancelled) deadline
        timer.tick()

        #expect(host.fadeCalled == false)
        #expect(host.isPlaying == true)
        #expect(timer.remaining == nil)
    }

    @Test func extendAddsTime() {
        let host = FakeHost()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let timer = makeTimer(host: host, clock: clock)

        timer.arm(.preset(minutes: 5))
        #expect(timer.remaining == 300)

        timer.addTime(minutes: 5)
        #expect(abs((timer.remaining ?? 0) - 600) < 1)   // ~10 minutes
    }

    // NOTE: the real volume ramp → 0 → pause ORDER (and the speaker-safety play()/muted
    // invariants) are covered in PlayerEngine's `PlaybackControllerTests` against a
    // `FakePlayerBackend` whose volume is observable — not duplicated here.

    // MARK: - Countdown semantics (the documented HIG decision)

    @Test func presetCountdownPausesWhilePlaybackPaused() {
        let host = FakeHost()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let timer = makeTimer(host: host, clock: clock)

        timer.arm(.preset(minutes: 10))   // 600s budget
        // Playing for 2 minutes → 480s remaining.
        host.isPlaying = true
        clock.advance(120)
        timer.tick()
        #expect(abs((timer.remaining ?? 0) - 480) < 1)

        // Paused for 5 minutes → budget must NOT drain.
        host.isPlaying = false
        clock.advance(300)
        timer.tick()
        #expect(abs((timer.remaining ?? 0) - 480) < 1)
        #expect(host.fadeCalled == false)

        // Resume and burn the rest → fires.
        host.isPlaying = true
        clock.advance(480)
        timer.tick()
        #expect(host.fadeCalled == true)
    }
}
