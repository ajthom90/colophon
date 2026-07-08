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
}
