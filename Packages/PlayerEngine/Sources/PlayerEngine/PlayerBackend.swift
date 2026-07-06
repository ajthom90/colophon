import Foundation
import AVFoundation

/// Playback engine seam: the controller drives pure timeline/sync logic over this
/// protocol, so its behavior is unit-testable without AVFoundation. The concrete
/// `AVQueuePlayerBackend` holds all the AV wiring (M0's inline code, unchanged in
/// behavior — including the atomic (index, offset) pair and the item-identity map).
@MainActor
public protocol PlayerBackend: AnyObject {
    var onTick: (() -> Void)? { get set }
    var onItemFinished: ((_ finishedIndex: Int, _ wasLast: Bool) -> Void)? { get set }
    /// Index + offset read off the SAME item — the atomic pair (M0 fix c27540a).
    var currentPosition: (index: Int, offset: TimeInterval)? { get }
    var playbackRate: Float { get set }
    var volume: Float { get set }
    func setQueue(urls: [URL], startIndex: Int, startOffset: TimeInterval)
    func play()
    func pause()
    func seek(toIndex index: Int, offset: TimeInterval)
    func teardown()
}

@MainActor
public final class AVQueuePlayerBackend: PlayerBackend {
    public var onTick: (() -> Void)?
    public var onItemFinished: ((Int, Bool) -> Void)?
    public var playbackRate: Float = 1.0 {
        didSet { player?.defaultRate = playbackRate; if isPlaying { player?.rate = playbackRate } }
    }
    public var volume: Float = 1.0 { didSet { player?.volume = volume } }

    private var player: AVQueuePlayer?
    private var urls: [URL] = []
    private var items: [AVPlayerItem] = []
    private var itemIndexByID: [ObjectIdentifier: Int] = [:]
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var isPlaying = false

    public init() {}

    public var currentPosition: (index: Int, offset: TimeInterval)? {
        guard let current = player?.currentItem,
              let index = itemIndexByID[ObjectIdentifier(current)] else { return nil }
        let offset = current.currentTime().seconds
        guard offset.isFinite else { return nil }
        return (index, offset)
    }

    public func setQueue(urls: [URL], startIndex: Int, startOffset: TimeInterval) {
        teardown()
        self.urls = urls
        items = urls.map { url in
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .spectral
            return item
        }
        rebuildIndex()
        let queue = AVQueuePlayer(items: Array(items[startIndex...]))
        queue.defaultRate = playbackRate
        queue.volume = volume
        player = queue
        queue.seek(to: CMTime(seconds: startOffset, preferredTimescale: 1000),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        installObservers(queue)
    }

    public func play() { isPlaying = true; player?.play(); player?.rate = playbackRate }
    public func pause() { isPlaying = false; player?.pause() }

    public func seek(toIndex index: Int, offset: TimeInterval) {
        guard let player else { return }
        if currentPosition?.index != index {
            player.removeAllItems()
            for original in items[index...] {
                let usable = original.currentTime() == .zero && player.canInsert(original, after: nil)
                    ? original
                    : AVPlayerItem(asset: original.asset)
                usable.audioTimePitchAlgorithm = .spectral
                if usable !== original, let i = items.firstIndex(where: { $0 === original }) {
                    items[i] = usable
                }
                player.insert(usable, after: nil)
            }
            rebuildIndex()
            if isPlaying { player.play(); player.rate = playbackRate }
        }
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func teardown() {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
        player?.pause(); player = nil
        items = []; itemIndexByID = [:]; isPlaying = false
    }

    private func rebuildIndex() {
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { (ObjectIdentifier($1), $0) })
    }

    private func installObservers(_ queue: AVQueuePlayer) {
        // Periodic observer is delivered on .main → safe to assume MainActor isolation.
        // The callback's `time` is ignored: by the time this runs, a boundary crossing may
        // have advanced `currentItem` to the NEXT track; `currentPosition` re-derives the
        // offset from the resolved current item, so (index, offset) are atomic by construction.
        timeObserver = queue.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        // NotificationCenter delivers on .main queue → safe to assume MainActor isolation.
        // `Notification`/`AVPlayerItem` are non-Sendable, so reduce the finished item to a
        // Sendable `ObjectIdentifier` BEFORE hopping onto the MainActor closure (M0 discipline).
        // Stale notifications from pre-rebuild queues are unmapped → harmless no-ops.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let finishedID = (note.object as? AVPlayerItem).map(ObjectIdentifier.init) else { return }
            MainActor.assumeIsolated {
                guard let self, let index = self.itemIndexByID[finishedID] else { return }
                self.onItemFinished?(index, index == self.items.count - 1)
            }
        }
    }
}
