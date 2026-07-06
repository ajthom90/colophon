import Foundation
@testable import PlayerEngine

@MainActor
final class FakePlayerBackend: PlayerBackend {
    var onTick: (() -> Void)?
    var onItemFinished: ((Int, Bool) -> Void)?
    var currentPosition: (index: Int, offset: TimeInterval)?
    var playbackRate: Float = 1.0
    var volume: Float = 1.0
    private(set) var queue: [URL] = []
    private(set) var playing = false
    private(set) var seeks: [(index: Int, offset: TimeInterval)] = []

    func setQueue(urls: [URL], startIndex: Int, startOffset: TimeInterval) {
        queue = urls
        currentPosition = (startIndex, startOffset)
    }
    func play() { playing = true }
    func pause() { playing = false }
    func seek(toIndex index: Int, offset: TimeInterval) {
        seeks.append((index, offset))
        currentPosition = (index, offset)
    }
    func teardown() { queue = []; currentPosition = nil; playing = false }

    /// Advance playback by `seconds` of TIMELINE time within the current track, then tick.
    func advance(by seconds: TimeInterval) {
        if let pos = currentPosition { currentPosition = (pos.index, pos.offset + seconds) }
        onTick?()
    }
    func moveTo(index: Int, offset: TimeInterval, thenTick: Bool = true) {
        currentPosition = (index, offset)
        if thenTick { onTick?() }
    }
}
