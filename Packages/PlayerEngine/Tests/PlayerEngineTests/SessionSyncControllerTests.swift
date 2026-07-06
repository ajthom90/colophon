import Foundation
import Testing
@testable import PlayerEngine

@Suite struct SessionSyncControllerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func emitsNothingBeforeInterval() {
        var sut = SessionSyncController(interval: 15)
        #expect(sut.noteProgress(currentTime: 1, listenedDelta: 1, now: t0) == nil)
        #expect(sut.noteProgress(currentTime: 14, listenedDelta: 13, now: t0.addingTimeInterval(13)) == nil)
    }

    @Test func emitsAccumulatedListenedTimeAtInterval() {
        var sut = SessionSyncController(interval: 15)
        _ = sut.noteProgress(currentTime: 5, listenedDelta: 5, now: t0.addingTimeInterval(5))
        let payload = sut.noteProgress(currentTime: 16, listenedDelta: 11, now: t0.addingTimeInterval(16))
        #expect(payload == SyncPayload(currentTime: 16, timeListened: 16))
    }

    @Test func didSyncResetsAccumulation() {
        var sut = SessionSyncController(interval: 15)
        _ = sut.noteProgress(currentTime: 16, listenedDelta: 16, now: t0.addingTimeInterval(16))
        sut.didSync()
        let payload = sut.noteProgress(currentTime: 32, listenedDelta: 16, now: t0.addingTimeInterval(32))
        #expect(payload == SyncPayload(currentTime: 32, timeListened: 16))
    }

    @Test func failedSyncKeepsAccumulating() {
        var sut = SessionSyncController(interval: 15)
        let first = sut.noteProgress(currentTime: 15, listenedDelta: 15, now: t0.addingTimeInterval(15))
        #expect(first?.timeListened == 15)
        // caller's POST failed → no didSync(); 15 more seconds pass
        let second = sut.noteProgress(currentTime: 30, listenedDelta: 15, now: t0.addingTimeInterval(30))
        #expect(second == SyncPayload(currentTime: 30, timeListened: 30))
    }

    @Test func flushEmitsRemainderOrNil() {
        var sut = SessionSyncController(interval: 15)
        #expect(sut.flush(currentTime: 0) == nil)
        _ = sut.noteProgress(currentTime: 4, listenedDelta: 4, now: t0.addingTimeInterval(4))
        #expect(sut.flush(currentTime: 4) == SyncPayload(currentTime: 4, timeListened: 4))
        sut.didSync()
        #expect(sut.flush(currentTime: 4) == nil)
    }

    @Test func seekingDoesNotCountAsListening() {
        var sut = SessionSyncController(interval: 15)
        // User scrubbed from 10 to 500: currentTime jumps, listenedDelta stays real.
        _ = sut.noteProgress(currentTime: 500, listenedDelta: 1, now: t0.addingTimeInterval(16))
        let payload = sut.flush(currentTime: 500)
        #expect(payload == SyncPayload(currentTime: 500, timeListened: 1))
    }

    @Test func accrualDuringInFlightSyncSurvivesDidSync() {
        var sut = SessionSyncController(interval: 15)
        // Emission captures 15s; while that POST is in flight, 4 more seconds accrue.
        let payload = sut.noteProgress(currentTime: 15, listenedDelta: 15, now: t0.addingTimeInterval(15))
        #expect(payload?.timeListened == 15)
        _ = sut.noteProgress(currentTime: 19, listenedDelta: 4, now: t0.addingTimeInterval(19))
        sut.didSync()   // server acked the 15s payload — the 4s must survive
        #expect(sut.flush(currentTime: 19) == SyncPayload(currentTime: 19, timeListened: 4))
    }

    @Test func flushThenDidSyncConsumesOnlyFlushedAmount() {
        var sut = SessionSyncController(interval: 15)
        _ = sut.noteProgress(currentTime: 5, listenedDelta: 5, now: t0.addingTimeInterval(5))
        let flushed = sut.flush(currentTime: 5)
        #expect(flushed?.timeListened == 5)
        _ = sut.noteProgress(currentTime: 7, listenedDelta: 2, now: t0.addingTimeInterval(7))
        sut.didSync()
        #expect(sut.flush(currentTime: 7) == SyncPayload(currentTime: 7, timeListened: 2))
    }

    @Test func accumulateOnlyNeverEmitsNorClobbersPendingEmission() {
        var sut = SessionSyncController(interval: 15)
        let payload = sut.noteProgress(currentTime: 15, listenedDelta: 15, now: t0.addingTimeInterval(15))
        #expect(payload?.timeListened == 15)          // pendingEmission = 15
        sut.accumulateOnly(listenedDelta: 20)          // would be "due" — must NOT emit or touch pendingEmission
        sut.didSync()                                  // acks the 15s payload only
        #expect(sut.flush(currentTime: 35) == SyncPayload(currentTime: 35, timeListened: 20))
    }
}
