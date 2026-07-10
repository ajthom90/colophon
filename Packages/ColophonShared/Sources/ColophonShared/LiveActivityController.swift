import Foundation

/// A plain, ActivityKit-free snapshot of the now-playing state the Live Activity lifecycle DECIDES on
/// (M2b Task 4). Kept free of ActivityKit — which is iOS-only — so the decision logic lives in this
/// cross-platform package and is unit-testable on the host WITHOUT a live ActivityKit host (which needs
/// a device). The app maps its `NowPlayingSnapshot` into this; the iOS-only `NowPlayingActivityAttributes`
/// (compiled into the app + widget extension) maps FROM this into ActivityKit's attributes + content.
public struct LiveActivityState: Sendable, Equatable {
    /// The library-item id (a book, or the owning podcast for an episode).
    public var itemID: String
    /// The episode id when this is a podcast episode; `nil` for a book.
    public var episodeID: String?
    public var title: String
    public var author: String
    /// The current chapter's title, when the book has chapters and one is active.
    public var chapterTitle: String?
    /// Fractional playback progress in `0...1`.
    public var progress: Double
    public var isPlaying: Bool
    /// Seconds elapsed into the book (for a monospaced-digits elapsed label on the surface).
    public var elapsed: TimeInterval
    /// App-Group-relative cover-thumbnail path — the extension reads the bytes from the shared
    /// container. `nil` until the app has written a thumbnail (it arrives asynchronously, via an update).
    public var artworkThumbnailPath: String?

    public init(
        itemID: String,
        episodeID: String? = nil,
        title: String,
        author: String,
        chapterTitle: String? = nil,
        progress: Double,
        isPlaying: Bool,
        elapsed: TimeInterval,
        artworkThumbnailPath: String? = nil
    ) {
        self.itemID = itemID
        self.episodeID = episodeID
        self.title = title
        self.author = author
        self.chapterTitle = chapterTitle
        self.progress = progress
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.artworkThumbnailPath = artworkThumbnailPath
    }

    /// The identity that decides "same book, update in place" vs "a switch, end-old-start-new" —
    /// the item plus (for a podcast) the episode.
    public var identity: String { itemID + "|" + (episodeID ?? "") }
}

/// The low-level ActivityKit operations the lifecycle DECISION logic drives, behind a protocol so a
/// fake can stand in for the real ActivityKit-backed manager in unit tests (ActivityKit needs a
/// device). The real implementation (app, iOS-only) wraps a single `Activity<NowPlayingActivityAttributes>`;
/// `isActive` is its source of truth for "exactly one Activity". ActivityKit is MainActor, so is this.
@MainActor
public protocol ActivityManaging: AnyObject {
    /// Whether the system currently permits Live Activities (`ActivityAuthorizationInfo`). Checked
    /// before a START so a disabled setting skips cleanly (an existing Activity can still be
    /// updated/ended).
    var areActivitiesEnabled: Bool { get }
    /// Whether this manager currently holds a live Activity.
    var isActive: Bool { get }
    /// Request a NEW Activity for `state`. Called only when `isActive == false` and enabled.
    func start(_ state: LiveActivityState)
    /// Update the live Activity's content state to `state`. Called only when `isActive`.
    func update(_ state: LiveActivityState)
    /// End + dismiss the live Activity. Called only when `isActive`.
    func end()
}

/// The now-playing Live Activity lifecycle DECISION logic (M2b Task 4) — the testable core that
/// decides, on each now-playing signal, whether to START, UPDATE, or END the Activity. It guarantees:
///
/// - **Start-if-enabled:** on the first signal for a playing item it starts an Activity only when
///   `ActivityAuthorizationInfo` permits it (else it skips cleanly, leaving nothing to leak).
/// - **Throttled updates:** chapter / play-pause / cover changes push IMMEDIATELY; a progress-only
///   change pushes at most once per `progressThrottle` seconds — ActivityKit has an update budget, so
///   we never push on every progress tick.
/// - **End-on-stop:** a `nil` signal (nothing playing — the authoritative clear a stop / retire /
///   sign-out publishes) ends the Activity.
/// - **Exactly one across switches:** a signal for a DIFFERENT item while one is live ends the old and
///   starts the new, so a book switch never leaves two Activities; the app's retire path additionally
///   clears (a `nil` signal) between books, which this handles idempotently.
///
/// Pure of ActivityKit: it drives an `ActivityManaging` seam, so the whole state machine is
/// unit-tested against a fake with no live ActivityKit host.
@MainActor
public final class LiveActivityController {
    private let manager: any ActivityManaging
    private let progressThrottle: TimeInterval
    private let now: () -> Date

    /// The identity of the Activity we believe is live (`nil` when none) + the last state we pushed +
    /// when we last pushed, for throttling progress-only updates.
    private var activeIdentity: String?
    private var lastState: LiveActivityState?
    private var lastUpdate: Date = .distantPast

    /// - Parameters:
    ///   - progressThrottle: the minimum spacing between progress-only updates (default 15s). Chapter /
    ///     play-pause / cover changes bypass it.
    ///   - now: injectable clock so the throttle is deterministically unit-testable.
    public init(
        manager: any ActivityManaging,
        progressThrottle: TimeInterval = 15,
        now: @escaping () -> Date = { Date() }
    ) {
        self.manager = manager
        self.progressThrottle = progressThrottle
        self.now = now
    }

    /// Drive the lifecycle from the current now-playing state (`nil` = nothing playing). Called on the
    /// SAME discrete signal that publishes the `NowPlayingSnapshot` (`onNowPlayingStateChange`), so a
    /// stop / retire / sign-out — each of which publishes a `nil` clear — ends the Activity, and a
    /// fresh play starts one.
    public func sync(_ state: LiveActivityState?) {
        guard let state else {
            endIfActive()
            return
        }
        guard manager.isActive else {
            startIfEnabled(state)
            return
        }
        if activeIdentity != state.identity {
            // A DIFFERENT book while one is live (defensive — the app's retire path clears first with a
            // `nil` sync): end the old and start the new so EXACTLY ONE is ever active.
            manager.end()
            clearTracking()
            startIfEnabled(state)
            return
        }
        // Same book: update in place. Chapter / play-pause / cover changes push at once; a progress-only
        // change is throttled to at most one push per `progressThrottle` seconds.
        if isSignificant(from: lastState, to: state) || now().timeIntervalSince(lastUpdate) >= progressThrottle {
            manager.update(state)
            record(state)
        }
    }

    // MARK: - Helpers

    private func startIfEnabled(_ state: LiveActivityState) {
        clearTracking()
        guard manager.areActivitiesEnabled else { return }
        manager.start(state)
        // The start can silently no-op (e.g. an ActivityKit request failure) — only record it as the
        // active Activity if the manager actually became active, so a failed start is retried on the
        // next signal instead of being remembered as live.
        guard manager.isActive else { return }
        record(state)
    }

    private func endIfActive() {
        if manager.isActive { manager.end() }
        clearTracking()
    }

    private func record(_ state: LiveActivityState) {
        activeIdentity = state.identity
        lastState = state
        lastUpdate = now()
    }

    private func clearTracking() {
        activeIdentity = nil
        lastState = nil
        lastUpdate = .distantPast
    }

    /// A change that must be reflected AT ONCE (never throttled): play/pause, chapter, cover arrival,
    /// or — defensively — title/author. Progress/elapsed alone are NOT significant, so they throttle.
    private func isSignificant(from old: LiveActivityState?, to new: LiveActivityState) -> Bool {
        guard let old else { return true }
        return old.isPlaying != new.isPlaying
            || old.chapterTitle != new.chapterTitle
            || old.artworkThumbnailPath != new.artworkThumbnailPath
            || old.title != new.title
            || old.author != new.author
    }
}
