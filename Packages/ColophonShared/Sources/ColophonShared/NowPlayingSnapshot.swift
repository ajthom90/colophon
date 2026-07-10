import Foundation

/// The now-playing state the app publishes into the App Group so the widget / Live Activity /
/// Control Center extensions (separate processes that cannot read the app's in-memory state) can
/// render the currently-playing book or episode. Display data ONLY — never tokens/credentials.
public struct NowPlayingSnapshot: Codable, Sendable, Equatable {
    /// The library-item id (a book, or the owning podcast for an episode).
    public var itemID: String
    /// The episode id when this is a podcast episode; `nil` for a book.
    public var episodeID: String?
    public var title: String
    /// The secondary line — the book's author, or (for an episode) the show name.
    public var author: String
    /// The current chapter's title, when the book has chapters and one is active.
    public var chapterTitle: String?
    /// Fractional playback progress in `0...1`.
    public var progress: Double
    public var isPlaying: Bool
    /// When this snapshot was written (the app's wall clock at publish time).
    public var updatedAt: Date
    /// Path to the cover thumbnail, RELATIVE to the App Group container. Resolve it with
    /// `SharedStore.readArtwork(atRelativePath:)` / `artworkURL(forRelativePath:)`. `nil` until the
    /// app has written a thumbnail (or when the item has no cover).
    public var artworkThumbnailPath: String?

    public init(
        itemID: String,
        episodeID: String? = nil,
        title: String,
        author: String,
        chapterTitle: String? = nil,
        progress: Double,
        isPlaying: Bool,
        updatedAt: Date,
        artworkThumbnailPath: String? = nil
    ) {
        self.itemID = itemID
        self.episodeID = episodeID
        self.title = title
        self.author = author
        self.chapterTitle = chapterTitle
        self.progress = progress
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.artworkThumbnailPath = artworkThumbnailPath
    }
}
