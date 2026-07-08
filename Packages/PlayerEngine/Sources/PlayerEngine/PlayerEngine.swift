import Foundation
import ABSKit
#if canImport(AVFAudio)
import AVFAudio
#endif

@MainActor
@Observable
public final class PlaybackController {
    public private(set) var isPlaying = false
    public private(set) var globalTime: TimeInterval = 0
    public private(set) var totalDuration: TimeInterval = 0
    public private(set) var title = ""
    public private(set) var author = ""
    public var rate: Float = 1.0 { didSet { backend.playbackRate = rate } }
    public var muted = false { didSet { backend.volume = muted ? 0 : 1 } }
    /// Seconds a single skip-forward/back jumps — the Settings-driven `colophon.skipInterval`
    /// preference (choices 10/15/30/45; default 15). The shell's `MiniPlayerBar`/`TransportBar`
    /// skip buttons read this directly, and `load()` hands it to `NowPlayingUpdater.configure` so the lock-screen /
    /// remote-command skip intervals match. The caller (`AppState.startPlayback`) sets it BEFORE
    /// calling `load()` on every fresh playback so `configure()` picks up the current value.
    public var skipInterval: Int = 15

    /// Return true if the payload reached the server (controller then resets the delta).
    public var onSyncDue: ((SyncPayload) async -> Bool)?

    private let backend: PlayerBackend
    private let now: @Sendable () -> Date
    private var timeline = BookTimeline(tracks: [])
    private var sync = SessionSyncController()
    private var lastTickGlobalTime: TimeInterval = 0
    private var syncInFlight = false
    private let nowPlaying = NowPlayingUpdater()

    public init(backend: PlayerBackend, now: @escaping @Sendable () -> Date = Date.init) {
        self.backend = backend
        self.now = now
        backend.onTick = { [weak self] in self?.tick() }
        backend.onItemFinished = { [weak self] index, wasLast in
            guard let self, wasLast else { return }
            self.globalTime = self.totalDuration
            self.pause()
        }
    }

    public func load(session: PlaybackSession, trackURLs: [URL]) {
        timeline = BookTimeline(tracks: session.audioTracks)
        totalDuration = timeline.totalDuration
        title = session.displayTitle ?? "Untitled"
        author = session.displayAuthor ?? ""
        sync = SessionSyncController()
        syncInFlight = false
        let start = timeline.position(at: session.startTime)
        backend.setQueue(urls: trackURLs, startIndex: start.trackIndex, startOffset: start.offset)
        globalTime = session.startTime
        lastTickGlobalTime = session.startTime
        nowPlaying.configure(controller: self)
        configureAudioSession()
    }

    public func play() { backend.play(); isPlaying = true; nowPlaying.update(controller: self) }

    public func pause() {
        backend.pause(); isPlaying = false
        nowPlaying.update(controller: self)
        Task { await flushSync() }
    }

    public func togglePlayPause() { isPlaying ? pause() : play() }
    public func skip(_ seconds: Double) { seek(toGlobal: globalTime + seconds) }
    public func setRate(_ newRate: Float) { rate = newRate }

    public func seek(toGlobal target: TimeInterval) {
        let position = timeline.position(at: target)
        backend.seek(toIndex: position.trackIndex, offset: position.offset)
        globalTime = timeline.globalTime(trackIndex: position.trackIndex, offset: position.offset)
        lastTickGlobalTime = globalTime
        nowPlaying.update(controller: self)
    }

    public func unload() { backend.teardown(); isPlaying = false }

    /// Flush any accumulated listened-time to the server WITHOUT pausing playback —
    /// used on scene backgrounding, where background audio must keep playing.
    public func flushOnly() async { await flushSync() }

    private func tick() {
        guard isPlaying, let position = backend.currentPosition else { return }
        globalTime = timeline.globalTime(trackIndex: position.index, offset: position.offset)
        let delta = max(0, globalTime - lastTickGlobalTime)
        lastTickGlobalTime = globalTime
        let listened = Double(delta) / Double(max(rate, 0.1))
        // AMENDED (Task 2 review finding): while a sync is in flight, only accumulate —
        // never let noteProgress emit, or an unsent payload clobbers pendingEmission and
        // the eventual didSync() over-consumes (lost listened seconds on slow networks).
        if syncInFlight || onSyncDue == nil {
            sync.accumulateOnly(listenedDelta: listened)
        } else if let payload = sync.noteProgress(currentTime: globalTime, listenedDelta: listened, now: now()),
                  let onSyncDue {
            syncInFlight = true
            Task {
                if await onSyncDue(payload) { self.sync.didSync() }
                self.syncInFlight = false
            }
        }
        nowPlaying.updateElapsed(controller: self)
    }

    private func flushSync() async {
        guard !syncInFlight, let payload = sync.flush(currentTime: globalTime), let onSyncDue else { return }
        syncInFlight = true
        if await onSyncDue(payload) { sync.didSync() }
        syncInFlight = false
    }

    private func configureAudioSession() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
