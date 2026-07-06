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

@Suite struct BookTimelineTests {
    // Three tracks: [0,10), [10,25), [25,30)
    let timeline = BookTimeline(tracks: [track(1, 0, 10), track(2, 10, 15), track(3, 25, 5)])

    @Test func totalDurationSumsTracks() {
        #expect(timeline.totalDuration == 30)
    }

    @Test func mapsGlobalTimeIntoTracks() {
        #expect(timeline.position(at: 0) == .init(trackIndex: 0, offset: 0))
        #expect(timeline.position(at: 9.5) == .init(trackIndex: 0, offset: 9.5))
        #expect(timeline.position(at: 10) == .init(trackIndex: 1, offset: 0))
        #expect(timeline.position(at: 24.9) == .init(trackIndex: 1, offset: 14.9))
        #expect(timeline.position(at: 29) == .init(trackIndex: 2, offset: 4))
    }

    @Test func clampsOutOfRange() {
        #expect(timeline.position(at: -5) == .init(trackIndex: 0, offset: 0))
        #expect(timeline.position(at: 30) == .init(trackIndex: 2, offset: 5))
        #expect(timeline.position(at: 999) == .init(trackIndex: 2, offset: 5))
    }

    @Test func globalTimeIsInverse() {
        #expect(timeline.globalTime(trackIndex: 1, offset: 14.9) == 24.9)
        #expect(timeline.globalTime(trackIndex: 0, offset: 0) == 0)
        #expect(timeline.globalTime(trackIndex: 2, offset: 4) == 29)
    }

    @Test func unsortedInputIsSorted() {
        let shuffled = BookTimeline(tracks: [track(3, 25, 5), track(1, 0, 10), track(2, 10, 15)])
        #expect(shuffled.position(at: 12) == .init(trackIndex: 1, offset: 2))
    }

    @Test func singleTrackBook() {
        let single = BookTimeline(tracks: [track(1, 0, 3600)])
        #expect(single.position(at: 1800) == .init(trackIndex: 0, offset: 1800))
        #expect(single.totalDuration == 3600)
    }
}
