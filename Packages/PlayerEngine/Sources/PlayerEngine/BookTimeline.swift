import Foundation
import ABSKit

/// Maps a book's single logical timeline onto its (possibly many) audio files.
/// `trackIndex` here is the position in the sorted array, NOT AudioTrack.index.
public struct BookTimeline: Sendable {
    public struct Position: Equatable, Sendable {
        public let trackIndex: Int
        public let offset: TimeInterval
        public init(trackIndex: Int, offset: TimeInterval) {
            self.trackIndex = trackIndex; self.offset = offset
        }

        public static func == (lhs: Position, rhs: Position) -> Bool {
            lhs.trackIndex == rhs.trackIndex &&
            abs(lhs.offset - rhs.offset) < 1e-9
        }
    }

    public let tracks: [AudioTrack]

    public init(tracks: [AudioTrack]) {
        self.tracks = tracks.sorted { $0.startOffset < $1.startOffset }
    }

    public var totalDuration: TimeInterval {
        guard let last = tracks.last else { return 0 }
        return last.startOffset + last.duration
    }

    public func position(at globalTime: TimeInterval) -> Position {
        guard !tracks.isEmpty else { return Position(trackIndex: 0, offset: 0) }
        let clamped = min(max(globalTime, 0), totalDuration)
        for (i, track) in tracks.enumerated() {
            let end = track.startOffset + track.duration
            if clamped < end || i == tracks.count - 1 {
                return Position(trackIndex: i, offset: min(clamped - track.startOffset, track.duration))
            }
        }
        return Position(trackIndex: 0, offset: 0)
    }

    public func globalTime(trackIndex: Int, offset: TimeInterval) -> TimeInterval {
        guard tracks.indices.contains(trackIndex) else { return 0 }
        return tracks[trackIndex].startOffset + offset
    }
}
