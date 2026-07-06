import Foundation
import AVFoundation
import ABSKit

@MainActor
@Observable
public final class PlaybackController {
    public private(set) var isPlaying = false
    public private(set) var globalTime: TimeInterval = 0
    public private(set) var totalDuration: TimeInterval = 0
    public private(set) var title = ""
    public private(set) var author = ""
    public var rate: Float = 1.0 { didSet { if isPlaying { player?.rate = rate } ; player?.defaultRate = rate } }

    /// Return true if the payload reached the server (controller then resets the delta).
    public var onSyncDue: ((SyncPayload) async -> Bool)?

    private var player: AVQueuePlayer?
    private var timeline = BookTimeline(tracks: [])
    private var items: [AVPlayerItem] = []
    /// Identity → track index for every live AVPlayerItem (rebuilt on load and queue rebuild).
    private var itemIndexByID: [ObjectIdentifier: Int] = [:]
    private var currentTrackIndex = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sync = SessionSyncController()
    private var syncInFlight = false
    private var lastTickGlobalTime: TimeInterval = 0
    private let nowPlaying = NowPlayingUpdater()

    public init() {}

    public func load(session: PlaybackSession, urlProvider: (AudioTrack) -> URL) {
        unload()
        timeline = BookTimeline(tracks: session.audioTracks)
        totalDuration = timeline.totalDuration
        title = session.displayTitle ?? "Untitled"
        author = session.displayAuthor ?? ""
        sync = SessionSyncController()

        items = timeline.tracks.map { track in
            let item = AVPlayerItem(url: urlProvider(track))
            item.audioTimePitchAlgorithm = .spectral
            return item
        }
        rebuildItemIndex()

        let start = timeline.position(at: session.startTime)
        let queue = AVQueuePlayer(items: Array(items[start.trackIndex...]))
        queue.defaultRate = rate
        currentTrackIndex = start.trackIndex
        player = queue
        queue.seek(to: CMTime(seconds: start.offset, preferredTimescale: 1000),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        globalTime = session.startTime
        lastTickGlobalTime = session.startTime

        installObservers(queue)
        nowPlaying.configure(controller: self)
        configureAudioSession()
    }

    public func play() {
        player?.play()
        player?.rate = rate
        isPlaying = true
        nowPlaying.update(controller: self)
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        nowPlaying.update(controller: self)
        Task { await flushSync() }
    }

    public func togglePlayPause() { isPlaying ? pause() : play() }

    public func skip(_ seconds: Double) { seek(toGlobal: globalTime + seconds) }

    public func seek(toGlobal target: TimeInterval) {
        guard let player else { return }
        let pos = timeline.position(at: target)
        if pos.trackIndex != currentTrackIndex {
            rebuildQueue(from: pos.trackIndex)
        }
        player.seek(to: CMTime(seconds: pos.offset, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        globalTime = timeline.globalTime(trackIndex: pos.trackIndex, offset: pos.offset)
        lastTickGlobalTime = globalTime
        nowPlaying.update(controller: self)
    }

    public func setRate(_ newRate: Float) { rate = newRate }

    public func unload() {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        itemIndexByID = [:]
    }

    // MARK: - Internals

    private func rebuildItemIndex() {
        itemIndexByID = Dictionary(uniqueKeysWithValues:
            items.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
    }

    private func rebuildQueue(from trackIndex: Int) {
        guard let player else { return }
        player.removeAllItems()
        for i in trackIndex..<items.count {
            let item = items[i]
            // Items can only be enqueued once; recreate if already played.
            let fresh = item.currentTime() == .zero && player.canInsert(item, after: nil)
                ? item
                : AVPlayerItem(asset: item.asset)
            fresh.audioTimePitchAlgorithm = .spectral
            items[i] = fresh
            player.insert(fresh, after: nil)
        }
        rebuildItemIndex()  // fresh items included; replaced items drop out (stale notifications no-op)
        currentTrackIndex = trackIndex
        if isPlaying { player.play(); player.rate = rate }
    }

    private func installObservers(_ queue: AVQueuePlayer) {
        // Periodic observer is delivered on .main → safe to assume MainActor isolation.
        timeObserver = queue.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(trackTime: time.seconds) }
        }
        // NotificationCenter delivers on .main queue → safe to assume MainActor isolation.
        // `Notification`/`AVPlayerItem` are non-Sendable, so reduce the finished item to a
        // Sendable `ObjectIdentifier` before hopping onto the MainActor closure.
        // Track advances are derived at tick time from the player's current item; this
        // handler ONLY detects end-of-book (the finished item is the last track's item).
        // Stale notifications from pre-rebuild queues are unmapped → harmless no-ops.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let finishedID = (note.object as? AVPlayerItem).map(ObjectIdentifier.init) else { return }
            MainActor.assumeIsolated {
                guard let self, !self.timeline.tracks.isEmpty,
                      self.itemIndexByID[finishedID] == self.timeline.tracks.count - 1 else { return }
                self.globalTime = self.totalDuration
                self.pause()  // book finished
            }
        }
    }

    private func tick(trackTime: TimeInterval) {
        guard isPlaying else { return }
        // Derive the track index from the queue's current item rather than counting
        // end notifications, which can be stale/duplicated across queue rebuilds.
        // Unmapped or nil current item → no state mutation this tick.
        guard let current = player?.currentItem,
              let index = itemIndexByID[ObjectIdentifier(current)] else { return }
        currentTrackIndex = index
        globalTime = timeline.globalTime(trackIndex: currentTrackIndex, offset: trackTime)
        let delta = max(0, globalTime - lastTickGlobalTime)
        lastTickGlobalTime = globalTime
        // Wall-clock listened time ≈ timeline delta / rate; ABS expects real seconds listened.
        let listened = Double(delta) / Double(max(rate, 0.1))
        // Always feed the accumulator; only spawn a sync when none is in flight.
        // A dropped payload's listened time stays accumulated — nothing is lost.
        let payload = sync.noteProgress(currentTime: globalTime, listenedDelta: listened, now: Date())
        if let payload, !syncInFlight, let onSyncDue {
            syncInFlight = true
            Task {
                if await onSyncDue(payload) { self.sync.didSync() }
                self.syncInFlight = false
            }
        }
        nowPlaying.updateElapsed(controller: self)
    }

    private func flushSync() async {
        guard !syncInFlight else { return }  // remainder stays accumulated for the next sync
        if let payload = sync.flush(currentTime: globalTime), let onSyncDue {
            syncInFlight = true
            if await onSyncDue(payload) { sync.didSync() }
            syncInFlight = false
        }
    }

    private func configureAudioSession() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, policy: .longFormAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
