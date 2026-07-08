import Foundation
import Testing
import ABSKit
@testable import PlayerEngine

@MainActor
private func makeSession() -> PlaybackSession {
    // Tracks: [0,10), [10,25), [25,30) — same shape as BookTimelineTests.
    let json = """
    {"id":"ses_t","libraryItemId":"li_t","displayTitle":"T","displayAuthor":"A",
     "duration":30,"startTime":0,"currentTime":0,"playMethod":0,"chapters":[],
     "audioTracks":[{"index":1,"startOffset":0,"duration":10},
                    {"index":2,"startOffset":10,"duration":15},
                    {"index":3,"startOffset":25,"duration":5}]}
    """
    return try! JSONDecoder().decode(PlaybackSession.self, from: Data(json.utf8))
}

@MainActor
private func makeSUT(startAt: TimeInterval = 0) -> (PlaybackController, FakePlayerBackend, ClockBox) {
    let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
    let backend = FakePlayerBackend()
    let controller = PlaybackController(backend: backend, now: { clock.now })
    let session = makeSession()
    controller.load(session: session, trackURLs: [
        URL(string: "https://t/1")!, URL(string: "https://t/2")!, URL(string: "https://t/3")!,
    ])
    if startAt > 0 { controller.seek(toGlobal: startAt) }
    controller.play()
    return (controller, backend, clock)
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

@MainActor @Suite struct PlaybackControllerTests {
    @Test func boundaryAdvanceIsContinuous() {
        let (controller, backend, clock) = makeSUT()
        clock.advance(9.5); backend.moveTo(index: 0, offset: 9.5)
        #expect(abs(controller.globalTime - 9.5) < 0.001)
        clock.advance(0.8); backend.moveTo(index: 1, offset: 0.3)   // crossed the 10s boundary
        #expect(abs(controller.globalTime - 10.3) < 0.001)
    }

    @Test func seekDoesNotCountAsListening() async {
        let (controller, backend, clock) = makeSUT()
        var payloads: [SyncPayload] = []
        controller.onSyncDue = { payloads.append($0); return true }
        clock.advance(13); backend.moveTo(index: 1, offset: 3)      // 13s real listening → globalTime 13, not yet due
        controller.seek(toGlobal: 26)                               // jump near the end
        #expect(backend.seeks.last!.index == 2)
        #expect(abs(backend.seeks.last!.offset - 1) < 0.001)
        clock.advance(3); backend.moveTo(index: 2, offset: 4)       // 3 more real seconds → 16s listened → due
        await Task.yield()                                          // let the spawned sync task append
        // 13s + 3s of real listening; the 13s seek jump (13→26) must not be counted.
        #expect(payloads.count == 1)
        #expect(abs(payloads[0].timeListened - 16) < 0.001)
        #expect(abs(payloads[0].currentTime - 29) < 0.001)
    }

    @Test func fastRateCountsWallClockListening() async {
        let (controller, backend, clock) = makeSUT()
        controller.setRate(2.0)
        var payloads: [SyncPayload] = []
        controller.onSyncDue = { payloads.append($0); return true }
        // 2× rate: 16s of timeline in 8s of wall time — but sync cadence needs 15s
        // of LISTENED time before the first emission (listened = timeline/rate = 8s). Not due yet.
        clock.advance(8); backend.advance(by: 16)
        await Task.yield()
        #expect(payloads.isEmpty)
        clock.advance(7); backend.moveTo(index: 1, offset: 20)      // total listened 15s
        await Task.yield()                                          // let the spawned sync task append
        #expect(payloads.count == 1)
        #expect(abs(payloads[0].timeListened - 15) < 0.01)
    }

    @Test func bookEndPausesAtTotalDuration() {
        let (controller, backend, _) = makeSUT()
        backend.moveTo(index: 2, offset: 4.9)
        backend.onItemFinished?(2, true)
        #expect(controller.isPlaying == false)
        #expect(controller.globalTime == controller.totalDuration)
    }

    @Test func staleFinishOfNonLastItemDoesNotPause() {
        let (controller, backend, _) = makeSUT()
        backend.onItemFinished?(0, false)
        #expect(controller.isPlaying == true)
    }

    @Test func syncsAreSerialized() async {
        let (controller, backend, clock) = makeSUT()
        var inFlight = 0, maxInFlight = 0, calls = 0
        controller.onSyncDue = { _ in
            inFlight += 1; calls += 1; maxInFlight = max(maxInFlight, inFlight)
            try? await Task.sleep(nanoseconds: 50_000_000)          // slow server
            inFlight -= 1
            return true
        }
        clock.advance(15); backend.advance(by: 15)                  // due → spawns sync task
        clock.advance(15); backend.advance(by: 1)                   // due again while first in flight
        try? await Task.sleep(nanoseconds: 200_000_000)             // let tasks drain
        #expect(maxInFlight == 1)
        #expect(calls >= 1)
    }

    @Test func mutedSetsBackendVolume() {
        let (controller, backend, _) = makeSUT()
        controller.muted = true
        #expect(backend.volume == 0)
        controller.muted = false
        #expect(backend.volume == 1)
    }

    // MARK: - Sleep-timer fade hook (Task 5)

    /// The fade ramp steps the backend volume down to exactly 0 over the injected duration and
    /// THEN pauses — order matters (the book fades out before playback stops, never a hard cut).
    /// The injected instant `sleepForFade` keeps this deterministic with no real 5s wait.
    @Test func fadeRampReachesZeroThenPauses() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let backend = FakePlayerBackend()
        // Instant per-step wait — no real sleeps.
        let controller = PlaybackController(backend: backend, now: { clock.now }, sleepForFade: { _ in })
        controller.load(session: makeSession(), trackURLs: [
            URL(string: "https://t/1")!, URL(string: "https://t/2")!, URL(string: "https://t/3")!,
        ])
        controller.play()
        #expect(controller.isPlaying == true)

        controller.fadeOutAndPause(over: 5, steps: 10)
        await controller.fadeTask?.value

        #expect(controller.isPlaying == false)
        #expect(backend.volume == 0)
        // Prove ordering: the volume reached 0 strictly before the pause was issued.
        let zeroIndex = backend.events.lastIndex(of: "vol:0.0")
        let pauseIndex = backend.events.lastIndex(of: "pause")
        #expect(zeroIndex != nil && pauseIndex != nil)
        #expect((zeroIndex ?? .max) < (pauseIndex ?? .min))
    }

    /// A no-op when nothing is playing (never pauses an already-paused/idle controller, and never
    /// touches the volume — the guard returns before any ramp).
    @Test func fadeIsNoOpWhenNotPlaying() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let backend = FakePlayerBackend()
        let controller = PlaybackController(backend: backend, now: { clock.now }, sleepForFade: { _ in })
        controller.load(session: makeSession(), trackURLs: [
            URL(string: "https://t/1")!, URL(string: "https://t/2")!, URL(string: "https://t/3")!,
        ])
        let volumeBefore = backend.volume
        // never played
        controller.fadeOutAndPause(over: 5, steps: 10)
        await controller.fadeTask?.value
        #expect(controller.isPlaying == false)
        #expect(backend.volume == volumeBefore)   // untouched — the ramp never ran
    }

    /// SPEAKER-SAFETY REGRESSION: after a fade parks the volume at 0 and pauses, resuming while
    /// `muted` must keep the volume at 0 — "muted still wins". If `play()`'s volume restore ever
    /// regressed to an unconditional `= 1`, this would blast audio out of the user's speakers.
    /// (Verified RED: changing `play()` to `backend.volume = 1` fails this test.)
    @Test func playWhileMutedAfterFadeKeepsVolumeZero() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let backend = FakePlayerBackend()
        let controller = PlaybackController(backend: backend, now: { clock.now }, sleepForFade: { _ in })
        controller.load(session: makeSession(), trackURLs: [
            URL(string: "https://t/1")!, URL(string: "https://t/2")!, URL(string: "https://t/3")!,
        ])
        controller.muted = true
        controller.play()
        #expect(backend.volume == 0)

        controller.fadeOutAndPause(over: 0.1, steps: 5)
        await controller.fadeTask?.value
        #expect(controller.isPlaying == false)
        #expect(backend.volume == 0)

        controller.play()
        #expect(controller.isPlaying == true)
        #expect(backend.volume == 0)   // muted still wins — NOT restored to 1
    }

    /// SPEAKER-SAFETY REGRESSION: a user `play()` DURING an in-flight fade must cancel the ramp and
    /// restore full volume — not leave it stuck at a partial (or 0) value, and not let the fade go
    /// on to pause afterwards. A blocking `sleepForFade` gate suspends the ramp mid-step so the
    /// `play()` lands while a fade is genuinely in flight. (Verified RED: dropping `play()`'s
    /// `fadeTask?.cancel()` + volume restore leaves the volume partial and re-pauses.)
    @Test func playMidFadeCancelsFadeAndRestoresVolume() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let backend = FakePlayerBackend()
        let gate = FadeSpinGate()
        let controller = PlaybackController(backend: backend, now: { clock.now }, sleepForFade: { _ in
            gate.markReached()
            while !gate.isReleased { await Task.yield() }
        })
        controller.load(session: makeSession(), trackURLs: [
            URL(string: "https://t/1")!, URL(string: "https://t/2")!, URL(string: "https://t/3")!,
        ])
        controller.play()
        #expect(backend.volume == 1)

        controller.fadeOutAndPause(over: 5, steps: 10)
        let fadeTask = controller.fadeTask
        // Let the ramp run its first step and suspend inside the gated sleep.
        while !gate.reached { await Task.yield() }
        #expect(backend.volume > 0 && backend.volume < 1)   // genuinely mid-fade

        controller.play()                                    // interrupt the fade
        #expect(controller.isPlaying == true)
        #expect(backend.volume == 1)                         // restored, not stuck partial

        gate.release()
        await fadeTask?.value                                 // let the cancelled ramp unwind
        #expect(backend.volume == 1)                         // fade did NOT complete to 0
        #expect(controller.isPlaying == true)                // fade did NOT re-pause
    }
}

/// Test-only lock-guarded gate: the fade's injected `sleepForFade` marks it reached on the first
/// step, then spins on `Task.yield()` until the test releases it — so a `play()` can land while a
/// fade is provably in flight. `@unchecked Sendable` (NSLock-guarded) so it's safe to touch from
/// both the fade closure and the test.
final class FadeSpinGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _reached = false
    private var _released = false
    var reached: Bool { lock.withLock { _reached } }
    var isReleased: Bool { lock.withLock { _released } }
    func markReached() { lock.withLock { _reached = true } }
    func release() { lock.withLock { _released = true } }
}
