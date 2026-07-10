import Foundation

/// The continue-listening shelf the app publishes into the App Group for the home-screen widget.
/// Display data ONLY — never tokens/credentials.
public struct ContinueListeningSnapshot: Codable, Sendable, Equatable {
    /// One in-progress book or episode the widget can show + deep-link to.
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var itemID: String
        public var episodeID: String?
        public var title: String
        public var author: String
        /// Fractional progress in `0...1`.
        public var progress: Double
        /// Cover-thumbnail path RELATIVE to the App Group container (see `NowPlayingSnapshot`).
        public var artworkThumbnailPath: String?

        /// Stable identity for `ForEach` — the 3-part key an item/episode is addressed by.
        public var id: String { itemID + "/" + (episodeID ?? "") }

        public init(
            itemID: String,
            episodeID: String? = nil,
            title: String,
            author: String,
            progress: Double,
            artworkThumbnailPath: String? = nil
        ) {
            self.itemID = itemID
            self.episodeID = episodeID
            self.title = title
            self.author = author
            self.progress = progress
            self.artworkThumbnailPath = artworkThumbnailPath
        }
    }

    public var entries: [Entry]

    /// The connection that PUBLISHED this snapshot (M2b Task 5). `SharedStore` holds a SINGLE shared
    /// continue-listening blob, last written by whichever connection's Home most recently published —
    /// it carries no connection identity on its own. `colophon://resume` / `ResumeIntent` start the top
    /// entry's `itemID` against the CURRENTLY-active connection's client, so they must gate on this
    /// matching the active connection: an `itemID` from a DIFFERENT / signed-out server must never be
    /// resumed. `nil` for a legacy blob written before this field existed (treated as non-matching, so a
    /// pre-upgrade blob never cross-resumes).
    public var connectionID: String?

    public init(entries: [Entry] = [], connectionID: String? = nil) {
        self.entries = entries
        self.connectionID = connectionID
    }
}
