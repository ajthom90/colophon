import Foundation
import Testing
import ABSKit
@testable import PlayerEngine

private func track(_ index: Int, _ start: Double, _ duration: Double) -> AudioTrack {
    let json = """
    {"index":\(index),"startOffset":\(start),"duration":\(duration)}
    """
    return try! JSONDecoder().decode(AudioTrack.self, from: Data(json.utf8))
}

/// Floating-point-tolerant position assertion. FP arithmetic in
/// `position(at:)` (e.g. 24.9 - 10) can be off by ~1e-15, so exact
/// `==` on offset is fragile; tolerance lives here in the tests, not
/// in the production type's Equatable.
private func expectPosition(
    _ actual: BookTimeline.Position,
    _ trackIndex: Int,
    _ offset: Double,
    tolerance: Double = 1e-9,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual.trackIndex == trackIndex, sourceLocation: sourceLocation)
    #expect(abs(actual.offset - offset) <= tolerance, sourceLocation: sourceLocation)
}

@Suite struct BookTimelineTests {
    // Three tracks: [0,10), [10,25), [25,30)
    let timeline = BookTimeline(tracks: [track(1, 0, 10), track(2, 10, 15), track(3, 25, 5)])

    @Test func totalDurationSumsTracks() {
        #expect(timeline.totalDuration == 30)
    }

    @Test func mapsGlobalTimeIntoTracks() {
        expectPosition(timeline.position(at: 0), 0, 0)
        expectPosition(timeline.position(at: 9.5), 0, 9.5)
        expectPosition(timeline.position(at: 10), 1, 0)
        expectPosition(timeline.position(at: 24.9), 1, 14.9)
        expectPosition(timeline.position(at: 29), 2, 4)
    }

    @Test func clampsOutOfRange() {
        expectPosition(timeline.position(at: -5), 0, 0)
        expectPosition(timeline.position(at: 30), 2, 5)
        expectPosition(timeline.position(at: 999), 2, 5)
    }

    @Test func globalTimeIsInverse() {
        #expect(abs(timeline.globalTime(trackIndex: 1, offset: 14.9) - 24.9) <= 1e-9)
        #expect(timeline.globalTime(trackIndex: 0, offset: 0) == 0)
        #expect(timeline.globalTime(trackIndex: 2, offset: 4) == 29)
    }

    @Test func unsortedInputIsSorted() {
        let shuffled = BookTimeline(tracks: [track(3, 25, 5), track(1, 0, 10), track(2, 10, 15)])
        expectPosition(shuffled.position(at: 12), 1, 2)
    }

    @Test func singleTrackBook() {
        let single = BookTimeline(tracks: [track(1, 0, 3600)])
        expectPosition(single.position(at: 1800), 0, 1800)
        #expect(single.totalDuration == 3600)
    }
}
