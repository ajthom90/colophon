import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import LibraryCache

/// Indexes the active connection's library items into Core Spotlight (M2b Task 5) so a system
/// Spotlight search surfaces books — tapping one hands the app an `NSUserActivity`
/// (`CSSearchableItemActionType`) whose identifier resolves back to `colophon://item/<id>` (see
/// `AppState.handleSpotlightActivity`).
///
/// CONSERVATIVE + PER-CONNECTION SCOPED: an item's `domainIdentifier` is its CONNECTION, so a whole
/// connection's items de-index together on sign-out / removal — items never leak across servers. The
/// `uniqueIdentifier` encodes `connectionID/itemID` so a Spotlight tap recovers BOTH, and the app
/// ignores a hit that isn't the ACTIVE connection's (a stale background-connection entry can't
/// cross-open another server's item). Only title/author (+ an optional cover thumbnail) are indexed.
///
/// Compiles on macOS too (Core Spotlight is cross-platform). Indexing is best-effort — a failed
/// index/delete is swallowed; Spotlight is additive, never load-bearing.
@MainActor
final class SpotlightIndexer {
    private let index: CSSearchableIndex

    init(index: CSSearchableIndex = .default()) { self.index = index }

    /// Per-connection domain — de-indexing a connection deletes exactly its items and nothing else.
    nonisolated static func domainIdentifier(connectionID: String) -> String {
        "colophon.connection." + connectionID
    }

    /// `connectionID/itemID` — recoverable by `components(fromUniqueIdentifier:)`. ABS connection and
    /// item ids carry no "/", so a single split on the first "/" is unambiguous.
    nonisolated static func uniqueIdentifier(connectionID: String, itemID: String) -> String {
        connectionID + "/" + itemID
    }

    /// Recovers `(connectionID, itemID)` from a Spotlight `uniqueIdentifier`, or nil if malformed.
    nonisolated static func components(fromUniqueIdentifier id: String) -> (connectionID: String, itemID: String)? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let connectionID = String(id[..<slash])
        let itemID = String(id[id.index(after: slash)...])
        guard !connectionID.isEmpty, !itemID.isEmpty else { return nil }
        return (connectionID, itemID)
    }

    /// PURE, unit-testable mapping: a cached item → its `CSSearchableItem` (title + author, an
    /// optional cover thumbnail, the per-connection domain + deep-linkable unique id).
    nonisolated static func searchableItem(
        for item: CachedItem, connectionID: String, thumbnailData: Data? = nil
    ) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        attributes.title = item.title
        attributes.artist = item.authorName
        attributes.contentDescription = item.authorName
        if let thumbnailData { attributes.thumbnailData = thumbnailData }
        return CSSearchableItem(
            uniqueIdentifier: uniqueIdentifier(connectionID: connectionID, itemID: item.id),
            domainIdentifier: domainIdentifier(connectionID: connectionID),
            attributeSet: attributes)
    }

    /// Index (upsert) a batch of cached items for a connection, resolving each item's optional cover
    /// thumbnail through the injected async provider (disk-only in production — no network). Runs off
    /// the caller's critical path in a `Task`; best-effort.
    ///
    /// TOCTOU GUARD: the thumbnail reads are awaited, so a sign-out (`deindex(connectionID:)`, which is
    /// synchronous) can complete WHILE this Task is in flight — the lagging write would otherwise
    /// resurrect the signed-out connection's items. `isStillActive` is re-checked on the MainActor
    /// immediately BEFORE the write; if the connection is no longer active/signed-in, the batch is
    /// dropped.
    func index(
        items: [CachedItem], connectionID: String,
        thumbnail: @escaping @Sendable (CachedItem) async -> Data?,
        isStillActive: @escaping @MainActor () -> Bool
    ) {
        guard !items.isEmpty else { return }
        let index = self.index
        Task {
            var searchables: [CSSearchableItem] = []
            searchables.reserveCapacity(items.count)
            for item in items {
                searchables.append(Self.searchableItem(
                    for: item, connectionID: connectionID, thumbnailData: await thumbnail(item)))
            }
            guard isStillActive() else { return }
            try? await index.indexSearchableItems(searchables)
        }
    }

    /// De-index a whole connection's items (sign-out / removal) so nothing leaks across servers.
    func deindex(connectionID: String) {
        index.deleteSearchableItems(
            withDomainIdentifiers: [Self.domainIdentifier(connectionID: connectionID)]) { _ in }
    }
}
