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
    /// preference (choices 10/15/30/45/60; default 30). The shell's `MiniPlayerBar`/`TransportBar`
    /// skip buttons and `FullPlayerView`'s transport read this directly (for both the jump AND the
    /// `gobackward.N`/`goforward.N` glyph), and `load()` hands it to `NowPlayingUpdater.configure`
    /// so the lock-screen / remote-command skip intervals match. `AppState` is the authority: it
    /// sets this from `storedSkipInterval()` BEFORE calling `load()` on every fresh playback (so
    /// `configure()` picks up the current value) and updates it live when the setting changes; this
    /// hard-coded default is only the never-hit fallback before the first `load()`.
    public var skipInterval: Int = 30

    /// Return true if the payload reached the server (controller then resets the delta).
    public var onSyncDue: ((SyncPayload) async -> Bool)?

    /// Fired ONCE when the current BOOK finishes — the backend played its LAST track to the end
    /// (`onItemFinished` with `wasLast == true`). This is the BOOK-level end signal (distinct from
    /// AVQueuePlayer's per-track sequencing, which stays inside the backend). `AppState` wires this
    /// to `advanceToNext()` (Task 8's up-next queue) so a finished book auto-advances to the next
    /// queued item — or stops when the queue is empty. The controller also pauses + parks
    /// `globalTime` at `totalDuration` before invoking it, so the UI reads "finished" either way.
    public var onBookFinished: (() -> Void)?

    private let backend: PlayerBackend
    private let now: @Sendable () -> Date
    private var timeline = BookTimeline(tracks: [])
    private var sync = SessionSyncController()
    private var lastTickGlobalTime: TimeInterval = 0
    private var syncInFlight = false
    private let nowPlaying = NowPlayingUpdater()
    /// One-shot latch so `onBookFinished` fires AT MOST ONCE per loaded session — hardens the
    /// AppState queue-advance against any double book-end from AVFoundation (a stale
    /// `didPlayToEndTime` notification, or a seek-to-end re-triggering the last item). Reset in
    /// `load()` when a fresh session is installed.
    private var didFireBookFinished = false

    /// The per-step wait the sleep-timer fade ramp awaits between volume decrements. Injectable so
    /// `fadeOutAndPause` is deterministic and instant in tests (inject a no-op) instead of burning
    /// the real ~5s. The production default is a genuine `Task.sleep`.
    private let sleepForFade: @Sendable (TimeInterval) async -> Void
    /// The in-flight fade ramp (Task 5's sleep-timer fire), so a fresh fade or a user `play()`
    /// cancels it. `internal` (not `private`) so the engine's `fadeRampReachesZeroThenPauses` test
    /// can `await fadeTask?.value` for a deterministic ramp completion.
    var fadeTask: Task<Void, Never>?

    public init(
        backend: PlayerBackend,
        now: @escaping @Sendable () -> Date = Date.init,
        sleepForFade: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.backend = backend
        self.now = now
        self.sleepForFade = sleepForFade
        backend.onTick = { [weak self] in self?.tick() }
        backend.onItemFinished = { [weak self] index, wasLast in
            guard let self, wasLast else { return }
            self.globalTime = self.totalDuration
            self.pause()
            // Fire the BOOK-finished signal AT MOST ONCE per session (the latch), AFTER pausing /
            // parking globalTime so a listener (AppState's queue advance) sees a consistent finished
            // state. The latch resets in `load()`; nil callback in the no-queue case.
            guard !self.didFireBookFinished else { return }
            self.didFireBookFinished = true
            self.onBookFinished?()
        }
    }

    public func load(session: PlaybackSession, trackURLs: [URL]) {
        timeline = BookTimeline(tracks: session.audioTracks)
        totalDuration = timeline.totalDuration
        didFireBookFinished = false   // fresh session → re-arm the one-shot book-finished latch
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

    public func play() {
        // A user-initiated play always aborts an in-flight sleep-timer fade AND restores audible
        // volume: without the restore, resuming right after a fade left the book silent (volume
        // parked at 0). `muted` (the E2E/CI safety switch) still wins.
        fadeTask?.cancel(); fadeTask = nil
        backend.volume = muted ? 0 : 1
        backend.play(); isPlaying = true; nowPlaying.update(controller: self)
    }

    /// Sleep-timer FIRE hook (Task 5): smoothly ramp the backend volume to 0 over `duration`
    /// seconds in `steps` increments, THEN `pause()` — so the book fades out rather than cutting
    /// off, and the pause is what the timer's UI/state observes. Order is guaranteed (volume hits 0
    /// before the pause). Fire-and-forget: it kicks off the ramp on `fadeTask` and returns, so the
    /// caller (`SleepTimer.fire`) stays synchronous; the wait between steps goes through the
    /// injected `sleepForFade` seam, so tests run it instantly and deterministically. A no-op if
    /// nothing is playing. Volume is restored on the next `play()`.
    public func fadeOutAndPause(over duration: TimeInterval, steps: Int = 20) {
        fadeTask?.cancel()
        guard isPlaying else { fadeTask = nil; return }
        let startVolume: Float = muted ? 0 : backend.volume
        let sleepStep = sleepForFade
        let stepCount = max(steps, 1)
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if duration > 0 {
                for step in 1...stepCount {
                    if Task.isCancelled { return }
                    let remainingFraction = Float(stepCount - step) / Float(stepCount)
                    self.backend.volume = startVolume * remainingFraction
                    await sleepStep(duration / Double(stepCount))
                }
            }
            if Task.isCancelled { return }
            self.backend.volume = 0
            self.pause()
        }
    }

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
