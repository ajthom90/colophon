#if os(iOS)
import ActivityKit
import ColophonShared
import Foundation

/// The ActivityKit attributes for the now-playing Live Activity (M2b Task 4). Compiled into BOTH the
/// app (which MANAGES the Activity via `LiveActivityManager`) and the `ColophonWidgets` extension
/// (which RENDERS it in `NowPlayingLiveActivity`) — the same shared-source pattern the playback intents
/// use — so a single definition backs both sides. iOS-only: ActivityKit is iOS-only, so the whole file
/// compiles away on the macOS app build.
///
/// STATIC attributes (fixed for the Activity's life): the item identity + title/author. The per-update
/// `ContentState` carries everything that changes while the book plays: chapter, progress, play/pause,
/// elapsed, and the (asynchronously-loaded) cover path.
struct NowPlayingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The active chapter's title, when the book has chapters.
        var chapterTitle: String?
        /// Fractional playback progress in `0...1`.
        var progress: Double
        var isPlaying: Bool
        /// Seconds elapsed into the book (for the monospaced-digits elapsed label).
        var elapsed: TimeInterval
        /// Total book/episode duration in seconds — the denominator for the self-advancing
        /// `ProgressView(timerInterval:)` and the end of the elapsed timer's range (M2b review #3).
        var duration: TimeInterval
        /// When this content was pushed (the app's wall clock). `updatedAt - elapsed` is the position
        /// ANCHOR the surface builds its self-advancing `timerInterval` range from.
        var updatedAt: Date
        /// App-Group-relative cover-thumbnail path; the extension reads the bytes from the shared
        /// container. `nil` until the cover thumbnail has been written (it arrives via an update).
        var artworkThumbnailPath: String?
    }

    /// The library-item id (a book, or the owning podcast for an episode).
    var itemID: String
    /// The episode id when this is a podcast episode; `nil` for a book.
    var episodeID: String?
    var title: String
    /// The secondary line — the book's author, or (for an episode) the show name.
    var author: String
}

extension NowPlayingActivityAttributes {
    /// The STATIC attributes for `state` (the fixed identity + title/author).
    init(state: LiveActivityState) {
        self.init(itemID: state.itemID, episodeID: state.episodeID,
                  title: state.title, author: state.author)
    }
}

extension NowPlayingActivityAttributes.ContentState {
    /// The per-update content state for `state`. `updatedAt` is stamped at build time — the moment the
    /// app pushes this content.
    init(state: LiveActivityState) {
        self.init(chapterTitle: state.chapterTitle, progress: state.progress,
                  isPlaying: state.isPlaying, elapsed: state.elapsed,
                  duration: state.duration, updatedAt: Date(),
                  artworkThumbnailPath: state.artworkThumbnailPath)
    }
}
#endif
