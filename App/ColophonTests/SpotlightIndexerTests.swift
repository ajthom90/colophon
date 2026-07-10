import Testing
import Foundation
import CoreSpotlight
import LibraryCache
@testable import Colophon

/// The item→`CSSearchableItem` mapping (M2b Task 5) + the unique-id round trip that lets a Spotlight
/// tap recover the item. Pure — no live `CSSearchableIndex` touched.
@MainActor
struct SpotlightIndexerTests {
    @Test func searchableItemMapsTitleAuthorDomainAndID() {
        let item = CachedItem(id: "book1", connectionID: "c1", libraryID: "lib1",
                              title: "Dune", authorName: "Herbert", updatedAt: 5)
        let searchable = SpotlightIndexer.searchableItem(for: item, connectionID: "c1")

        #expect(searchable.uniqueIdentifier == "c1/book1")
        #expect(searchable.domainIdentifier == "colophon.connection.c1")
        #expect(searchable.attributeSet.title == "Dune")
        #expect(searchable.attributeSet.artist == "Herbert")
        // Conservative: no thumbnail unless one is provided.
        #expect(searchable.attributeSet.thumbnailData == nil)
    }

    @Test func searchableItemCarriesThumbnailWhenProvided() {
        let item = CachedItem(id: "b", connectionID: "c1", libraryID: "l", title: "T")
        let data = Data([0x1, 0x2, 0x3])
        let searchable = SpotlightIndexer.searchableItem(for: item, connectionID: "c1", thumbnailData: data)
        #expect(searchable.attributeSet.thumbnailData == data)
    }

    @Test func uniqueIdentifierRoundTrips() {
        let id = SpotlightIndexer.uniqueIdentifier(connectionID: "c1", itemID: "book1")
        let parts = SpotlightIndexer.components(fromUniqueIdentifier: id)
        #expect(parts?.connectionID == "c1")
        #expect(parts?.itemID == "book1")
        // A malformed identifier (no separator) yields nil rather than a bogus route.
        #expect(SpotlightIndexer.components(fromUniqueIdentifier: "nosep") == nil)
    }

    @Test func domainIdentifierIsPerConnection() {
        #expect(SpotlightIndexer.domainIdentifier(connectionID: "c1")
                != SpotlightIndexer.domainIdentifier(connectionID: "c2"))
    }
}
