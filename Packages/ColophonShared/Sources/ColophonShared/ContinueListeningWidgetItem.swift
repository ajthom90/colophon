import Foundation

/// One continue-listening entry SHAPED for widget display — decoupled from WidgetKit's
/// `TimelineEntry`/`Date` so the snapshot→display mapping below is a pure, unit-testable function
/// with no widget host (or even `import WidgetKit`) required.
public struct ContinueListeningWidgetItem: Sendable, Equatable, Identifiable {
    public var itemID: String
    public var episodeID: String?
    public var title: String
    public var author: String
    /// Fractional progress in `0...1`.
    public var progress: Double
    public var artworkThumbnailPath: String?

    public var id: String { itemID + "/" + (episodeID ?? "") }

    /// Where tapping this item in the widget deep-links to.
    public var deepLinkURL: URL { ColophonDeepLink.item(id: itemID, episodeID: episodeID).url }

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

    init(entry: ContinueListeningSnapshot.Entry) {
        self.init(
            itemID: entry.itemID,
            episodeID: entry.episodeID,
            title: entry.title,
            author: entry.author,
            progress: entry.progress,
            artworkThumbnailPath: entry.artworkThumbnailPath)
    }
}

extension ContinueListeningSnapshot {
    /// The most items any current widget family displays (`.systemMedium` shows up to 3 rows).
    /// Callers preparing widget-only side effects (e.g. fetching/writing artwork thumbnails) can
    /// cap their own work at this same number, so the app never spends a fetch on an entry no
    /// widget will ever render.
    public static let maxWidgetDisplayCount = 3

    /// Maps the snapshot into widget-display items, in the snapshot's own order (most-recent-first
    /// — the app publishes the continue-listening shelf in server order), capped at `limit`. Pure
    /// and deterministic: the SAME function drives both the small (`limit: 1`) and medium
    /// (`limit: maxWidgetDisplayCount`) widget families AND their unit tests.
    public func widgetItems(limit: Int = maxWidgetDisplayCount) -> [ContinueListeningWidgetItem] {
        entries.prefix(limit).map(ContinueListeningWidgetItem.init(entry:))
    }
}
