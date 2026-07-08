import Testing
import Foundation
import ABSKit
import LibraryCache
@testable import Colophon

/// Deterministic proof for `SearchModel` — the blended local-FTS5 ⨯ server search core (Task 10).
/// Every test injects fakes for both tiers and drives debounce/cancellation with a continuation
/// `Gate` (no real sleeps, no wall-clock waits): `debounce: .zero` collapses the debounce, and the
/// server fn parks inside `gate.enter()` so a test can observe the exact instant BEFORE the server
/// result is applied, then release it. This makes "local paints first", "a superseded result is
/// dropped", and "entity buckets are server-only" all observable without polling.
@MainActor
struct SearchModelTests {
    // MARK: - Helpers

    /// A two-sided continuation gate: the server fn calls `enter()` (signals it arrived, then parks
    /// until released); the test awaits `waitEntered()` (returns once the server fn has arrived —
    /// which, by construction, is strictly AFTER the local tier has painted) and later `release()`.
    private actor Gate {
        private var entered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func enter() async {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            if released { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    /// Records the exact queries the server fn was invoked with — proves the empty/1-char guard.
    @MainActor private final class CallLog {
        var serverQueries: [String] = []
    }

    /// Decodes a `SearchResults` from JSON — exercises the real DTO decode path while letting each
    /// test script an arbitrary bucket shape (the struct has no public memberwise init).
    private func makeResults(_ json: String) throws -> SearchResults {
        try JSONDecoder().decode(SearchResults.self, from: Data(json.utf8))
    }

    private func localRow(id: String, title: String, author: String? = nil,
                          duration: Double? = nil, updatedAt: Int? = nil) -> ItemRow {
        ItemRow(cachedItem: CachedItem(
            id: id, connectionID: "c", libraryID: "l", title: title,
            authorName: author, duration: duration, updatedAt: updatedAt))
    }

    // MARK: - Tests

    /// The instant local tier paints `titles` before the server result is applied — asserted at the
    /// moment the server fn has been reached (local already ran) but is still parked.
    @Test func localResultsPaintBeforeServer() async {
        let gate = Gate()
        let row = localRow(id: "i1", title: "The Art of War", author: "Sun Tzu")
        let model = SearchModel(
            localSearch: { _ in [row] },
            serverSearch: { _ in
                await gate.enter()
                return try self.makeResults(#"{"authors":[{"id":"a1","name":"Sun Tzu","numBooks":1}]}"#)
            },
            debounce: .zero)

        model.updateQuery("art")
        await gate.waitEntered()

        #expect(model.titles == [row])            // local painted
        #expect(model.isSearching == true)        // server tier in flight
        #expect(model.authors.isEmpty)            // server not yet merged
        #expect(model.populatedSections == [.titles])

        await gate.release()
        await model.pendingSearch?.value

        #expect(model.authors.map(\.name) == ["Sun Tzu"])
        #expect(model.isSearching == false)
    }

    /// Dedup by id: an FTS placeholder and the server `book` hit share an id → ONE row, server-
    /// enriched, with the FTS row's cover cache-buster carried over.
    @Test func serverRowReplacesLocalPlaceholderById() async {
        let placeholder = localRow(id: "i1", title: "The Art of War", author: nil, updatedAt: 42)
        let model = SearchModel(
            localSearch: { _ in [placeholder] },
            serverSearch: { _ in try self.makeResults(#"""
                {"book":[{"libraryItem":{"id":"i1","media":{"duration":3600,
                "metadata":{"title":"The Art of War","subtitle":"A Manual","authorName":"Sun Tzu"}}}}]}
                """#) },
            debounce: .zero)

        model.updateQuery("art")
        await model.pendingSearch?.value

        #expect(model.titles.count == 1)          // one row per id
        let row = model.titles[0]
        #expect(row.id == "i1")
        #expect(row.isServerEnriched == true)     // server row won
        #expect(row.author == "Sun Tzu")          // enriched from server
        #expect(row.subtitle == "A Manual")
        #expect(row.duration == 3600)
        #expect(row.updatedAt == 42)              // carried over from the FTS placeholder
    }

    /// Query A parks in the server tier; query B supersedes it. A's late server result is discarded
    /// (its task is cancelled), so only B's local + server data is visible.
    @Test func cancellationDropsSupersededResults() async {
        let gateA = Gate(); let gateB = Gate()
        let rowA = localRow(id: "a1", title: "Query A book")
        let rowB = localRow(id: "b1", title: "Query B book")
        let model = SearchModel(
            localSearch: { q in q == "aa" ? [rowA] : [rowB] },
            serverSearch: { q in
                if q == "aa" {
                    await gateA.enter()
                    return try self.makeResults(#"{"authors":[{"id":"a","name":"Author A","numBooks":1}]}"#)
                } else {
                    await gateB.enter()
                    return try self.makeResults(#"{"authors":[{"id":"b","name":"Author B","numBooks":1}]}"#)
                }
            },
            debounce: .zero)

        model.updateQuery("aa")
        let taskA = model.pendingSearch
        await gateA.waitEntered()          // A parked in the server tier

        model.updateQuery("bb")            // cancels A, starts B
        let taskB = model.pendingSearch
        await gateB.waitEntered()          // B parked in the server tier

        await gateA.release()              // A's server fn returns — but A is cancelled → dropped
        await taskA?.value
        await gateB.release()              // B's result is applied
        await taskB?.value

        #expect(model.titles == [rowB])                       // B's local rows, not A's
        #expect(model.authors.map(\.name) == ["Author B"])    // only B's server bucket
        #expect(model.isSearching == false)
    }

    /// The server is NEVER called for an empty or 1-char query (the endpoint 400s on those); a
    /// 2-char query does reach it exactly once.
    @Test func emptyOrSingleCharNeverHitsServer() async {
        let log = CallLog()
        let model = SearchModel(
            localSearch: { _ in [] },
            serverSearch: { q in log.serverQueries.append(q); return try self.makeResults("{}") },
            debounce: .zero)

        model.updateQuery("")
        await model.pendingSearch?.value
        #expect(log.serverQueries.isEmpty)

        model.updateQuery("a")
        await model.pendingSearch?.value
        #expect(log.serverQueries.isEmpty)         // 1 char: still local-only

        model.updateQuery("ar")
        await model.pendingSearch?.value
        #expect(log.serverQueries == ["ar"])       // 2 chars: server fires, once
    }

    /// Entity buckets (Series/Authors/Narrators/Genres/Tags) appear ONLY after the server response,
    /// in the canonical section order Titles → Series → Authors → Narrators → Genres → Tags.
    @Test func entityBucketsAreServerOnlyAndOrdered() async {
        let gate = Gate()
        let row = localRow(id: "i1", title: "The Art of War")
        let fullJSON = #"""
        {
          "book":[{"libraryItem":{"id":"i1","media":{"metadata":{"title":"The Art of War"}}}}],
          "series":[{"series":{"id":"s1","name":"Warfare"}}],
          "authors":[{"id":"a1","name":"Sun Tzu","numBooks":1}],
          "narrators":[{"name":"A Narrator","numBooks":2}],
          "genres":[{"name":"History","numItems":5}],
          "tags":[{"name":"Classic","numItems":3}]
        }
        """#
        let model = SearchModel(
            localSearch: { _ in [row] },
            serverSearch: { _ in await gate.enter(); return try self.makeResults(fullJSON) },
            debounce: .zero)

        model.updateQuery("war")
        await gate.waitEntered()
        #expect(model.populatedSections == [.titles])          // server-only buckets not yet present

        await gate.release()
        await model.pendingSearch?.value

        #expect(model.populatedSections == [.titles, .series, .authors, .narrators, .genres, .tags])
        #expect(model.series.map(\.name) == ["Warfare"])
        #expect(model.authors.map(\.name) == ["Sun Tzu"])
        #expect(model.narrators.map(\.name) == ["A Narrator"])
    }
}
