import Testing
@testable import Colophon

/// Deterministic proof for `ShelfCardRouting.isPodcastBookEntity` — the podcast-vs-book routing
/// decision M1c-c Task 7 pulled out of `ShelfRow.card(for:)` (grounded in `podcast-personalized.json`
/// + `personalized.json` — see the type's own doc comment for the full source-fixture reasoning).
///
/// Fix round 2: every `recently-added` shelf entity carries its OWN top-level `mediaType`
/// (`"podcast"` / `"book"`, live-verified against both fixtures), so the routing PREFERS that precise
/// per-entity signal and only falls back to the enclosing `Shelf.type` when the entity omits it.
@Suite struct ShelfCardRoutingTests {

    // MARK: - Per-entity mediaType (preferred signal)

    @Test func podcastEntityMediaTypeRoutesToPodcastDetail() {
        // Even if the shelf type somehow disagreed, the entity's own "podcast" wins.
        #expect(ShelfCardRouting.isPodcastBookEntity(entityMediaType: "podcast", shelfType: "book"))
    }

    @Test func bookEntityMediaTypeDoesNotRouteToPodcastDetail() {
        // Even if the shelf type somehow said "podcast", the entity's own "book" wins → book route.
        #expect(!ShelfCardRouting.isPodcastBookEntity(entityMediaType: "book", shelfType: "podcast"))
    }

    // MARK: - Fallback to Shelf.type when the entity omits mediaType

    @Test func podcastLibraryShelfTypeRoutesToPodcastDetailWhenEntityMediaTypeAbsent() {
        #expect(ShelfCardRouting.isPodcastBookEntity(entityMediaType: nil, shelfType: "podcast"))
        #expect(ShelfCardRouting.isPodcastBookEntity(entityMediaType: "", shelfType: "podcast"))
    }

    @Test func bookLibraryShelfTypeDoesNotRouteToPodcastDetailWhenEntityMediaTypeAbsent() {
        #expect(!ShelfCardRouting.isPodcastBookEntity(entityMediaType: nil, shelfType: "book"))
        #expect(!ShelfCardRouting.isPodcastBookEntity(entityMediaType: "", shelfType: "book"))
    }

    /// The `authors`-typed shelf never hosts a `.book` entity in practice (its entities decode as
    /// `.author`), but the routing check itself must still fail closed for any non-"podcast" type
    /// with no entity mediaType — never accidentally misroute on an unrecognized/future shape.
    @Test func unrecognizedShelfTypeDoesNotRouteToPodcastDetailWhenEntityMediaTypeAbsent() {
        #expect(!ShelfCardRouting.isPodcastBookEntity(entityMediaType: nil, shelfType: "authors"))
        #expect(!ShelfCardRouting.isPodcastBookEntity(entityMediaType: nil, shelfType: ""))
    }
}
