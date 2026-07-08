import Testing
@testable import Colophon

/// Deterministic proof for `ShelfCardRouting.isPodcastBookEntity` — the podcast-vs-book routing
/// decision M1c-c Task 7 pulled out of `ShelfRow.card(for:)` (grounded in `podcast-personalized.json`
/// — see the type's own doc comment for the full source-fixture reasoning). A `.book`-shaped shelf
/// entity carries no `mediaType` of its own; the ONLY signal available is the enclosing `Shelf.type`,
/// which is `"podcast"` for a podcast library's `recently-added` shelf and `"book"` for a book
/// library's own `recently-added` (both live-captured, `podcast-personalized.json` / `personalized.json`).
@Suite struct ShelfCardRoutingTests {
    @Test func podcastLibraryRecentlyAddedShelfRoutesToPodcastDetail() {
        #expect(ShelfCardRouting.isPodcastBookEntity(shelfType: "podcast"))
    }

    @Test func bookLibraryRecentlyAddedShelfDoesNotRouteToPodcastDetail() {
        #expect(!ShelfCardRouting.isPodcastBookEntity(shelfType: "book"))
    }

    /// The `authors`-typed shelf never hosts a `.book` entity in practice (its entities decode as
    /// `.author`), but the routing check itself must still fail closed for any non-"podcast" type —
    /// never accidentally misroute on an unrecognized/future shelf `type`.
    @Test func unrecognizedShelfTypeDoesNotRouteToPodcastDetail() {
        #expect(!ShelfCardRouting.isPodcastBookEntity(shelfType: "authors"))
        #expect(!ShelfCardRouting.isPodcastBookEntity(shelfType: "episode"))
        #expect(!ShelfCardRouting.isPodcastBookEntity(shelfType: ""))
    }
}
