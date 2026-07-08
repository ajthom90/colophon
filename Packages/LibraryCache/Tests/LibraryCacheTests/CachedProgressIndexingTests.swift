import Foundation
import Testing
@testable import LibraryCache

/// `[CachedProgress].indexedByItem()` is the merge rule shared by every progress-pill surface
/// (Home shelves, the library grid, and M1c-a Task 9's author/series detail grids) — pulled out
/// of each view's duplicated `observeProgress` closure so the rule is defined once and is
/// independently testable here rather than only indirectly via SwiftUI view state.
@Suite struct CachedProgressIndexingTests {
    private func progress(
        item: String, episode: String = "", currentTime: Double = 0,
        finished: Bool = false, lastUpdate: Int = 0
    ) -> CachedProgress {
        CachedProgress(connectionID: "C1", itemID: item, episodeID: episode,
                       currentTime: currentTime, isFinished: finished, lastUpdate: lastUpdate)
    }

    @Test func bookRowWinsOverEpisodeRowOnCollision() {
        let book = progress(item: "i1", episode: "", lastUpdate: 1)
        let episode = progress(item: "i1", episode: "ep1", lastUpdate: 999) // newer, but episode-style
        let indexed = [episode, book].indexedByItem()
        #expect(indexed["i1"]?.episodeID == "")
    }

    @Test func newestLastUpdateWinsWhenBothSameStyle() {
        let older = progress(item: "i1", lastUpdate: 100)
        let newer = progress(item: "i1", lastUpdate: 200)
        let indexed = [older, newer].indexedByItem()
        #expect(indexed["i1"]?.lastUpdate == 200)
    }

    @Test func distinctItemsAllIndexed() {
        let a = progress(item: "i1")
        let b = progress(item: "i2")
        let indexed = [a, b].indexedByItem()
        #expect(indexed.count == 2)
        #expect(indexed["i1"] != nil && indexed["i2"] != nil)
    }

    @Test func emptyInputIndexesToEmpty() {
        let indexed = [CachedProgress]().indexedByItem()
        #expect(indexed.isEmpty)
    }

    // MARK: - `indexedByItemAndEpisode()` (M1c-c Task 7 — per-episode shelf-card progress)

    /// Two episodes of the SAME podcast share one `itemID` — `indexedByItem()` would collapse them
    /// to a single row, but a home shelf needs BOTH episodes' progress distinctly (one card per
    /// episode). This is the exact scenario `indexedByItem()` cannot serve.
    @Test func episodeRowsForTheSameItemAreIndexedDistinctly() {
        let ep1 = progress(item: "podcast1", episode: "epA", currentTime: 100, lastUpdate: 1)
        let ep2 = progress(item: "podcast1", episode: "epB", currentTime: 200, lastUpdate: 2)
        let indexed = [ep1, ep2].indexedByItemAndEpisode()
        #expect(indexed.count == 2)
        #expect(indexed["podcast1/epA"]?.currentTime == 100)
        #expect(indexed["podcast1/epB"]?.currentTime == 200)
    }

    /// A book-style row (empty `episodeID`) keys with a trailing slash and no episode suffix — the
    /// same key shape a caller builds via `itemID + "/" + episodeID` when `episodeID` is `""`.
    @Test func bookRowKeysWithEmptyEpisodeSuffix() {
        let book = progress(item: "book1")
        let indexed = [book].indexedByItemAndEpisode()
        #expect(indexed["book1/"] != nil)
    }

    /// A genuine key collision (should not happen for real `cachedProgress` PK rows, but the merge
    /// rule is still well-defined): the newest `lastUpdate` wins, unlike `indexedByItem()` which
    /// additionally prefers a book-style row on style mismatch — irrelevant here since both rows
    /// share the same `(itemID, episodeID)` and thus the same style.
    @Test func newestLastUpdateWinsOnKeyCollision() {
        let older = progress(item: "podcast1", episode: "epA", lastUpdate: 100)
        let newer = progress(item: "podcast1", episode: "epA", currentTime: 50, lastUpdate: 200)
        let indexed = [older, newer].indexedByItemAndEpisode()
        #expect(indexed["podcast1/epA"]?.lastUpdate == 200)
        #expect(indexed["podcast1/epA"]?.currentTime == 50)
    }

    /// A podcast episode's progress never bleeds into a lookup for a DIFFERENT episode of the same
    /// podcast, nor into a lookup for the podcast's own (nonexistent) book-style row — proving the
    /// "distinct from any book progress for the same item" requirement.
    @Test func episodeProgressDoesNotBleedIntoBookOrSiblingLookup() {
        let episode = progress(item: "podcast1", episode: "epA", currentTime: 42, lastUpdate: 1)
        let indexed = [episode].indexedByItemAndEpisode()
        #expect(indexed["podcast1/epA"]?.currentTime == 42)
        #expect(indexed["podcast1/"] == nil)        // no book-style row for this podcast
        #expect(indexed["podcast1/epB"] == nil)     // no row for a sibling episode
    }

    @Test func emptyInputIndexesToEmptyForItemAndEpisode() {
        let indexed = [CachedProgress]().indexedByItemAndEpisode()
        #expect(indexed.isEmpty)
    }
}
