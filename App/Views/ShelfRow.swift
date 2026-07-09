import SwiftUI
import ABSKit
import LibraryCache

/// One personalized-shelf row: a plain, OPAQUE section header (the shelf's `label`, HIG section
/// styling — never glass) above a horizontally-scrolling `LazyHStack` of cards, `.viewAligned` so
/// swipes settle card-to-card like Apple Music / Books. The card kind is chosen per entity
/// (book → `CoverCard`, author → `AuthorCard`, episode → `EpisodeCard`, M1c-c Task 7's real,
/// tappable episode card — replacing the M1c-a `EpisodeStubCard`). Progress for book/podcast cards
/// is resolved via the injected `progressFor` lookup; episode cards resolve their OWN progress via
/// `episodeProgressFor` (the 3-part `(itemID, episodeID)` key — see `ShelfCardRouting`'s sibling doc
/// on `HomeView.progressByItemEpisode`), both fed by the home view's live `CachedProgress`
/// observation, so pills update without a shelf refetch.
struct ShelfRow: View {
    @Environment(AppState.self) private var app
    let shelf: Shelf
    let progressFor: (String) -> CachedProgress?
    /// Resolves an episode's OWN `cachedProgress` row by `(podcastItemID, episodeID)` — distinct from
    /// any book-style progress on the same item and from any sibling episode's progress.
    let episodeProgressFor: (String, String) -> CachedProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shelf.label)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(shelf.entities.enumerated()), id: \.offset) { _, entity in
                        card(for: entity)
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .task(id: shelf.id) { await prefetchCovers() }
    }

    @ViewBuilder
    private func card(for entity: ShelfEntity) -> some View {
        switch entity {
        case .book(let book):
            CoverCard(
                itemID: book.id,
                updatedAt: nil,
                title: book.media.metadata.title ?? "Untitled",
                // A podcast's shelf-entity metadata reports its author as "author" (singular), not
                // the book field "authorName" — fall back so a podcast recently-added card still
                // shows its author (see `ShelfEntityMetadata.author`'s doc comment).
                author: book.media.metadata.authorName ?? book.media.metadata.author,
                duration: book.media.duration,
                progress: progressFor(book.id),
                // Prefer the entity's OWN mediaType (live-verified present on every recently-added
                // entity); fall back to the shelf's type only if the entity ever omits it.
                isPodcast: ShelfCardRouting.isPodcastBookEntity(
                    entityMediaType: book.mediaType, shelfType: shelf.type))
        case .author(let author):
            AuthorCard(name: author.name)
        case .episode(let episode):
            if let recentEpisode = episode.recentEpisode, let episodeID = recentEpisode.id {
                EpisodeCard(
                    podcastItemID: episode.id,
                    episodeID: episodeID,
                    title: recentEpisode.title ?? "Episode",
                    podcastTitle: episode.media?.metadata.title ?? "Podcast",
                    duration: recentEpisode.effectiveDuration,
                    updatedAt: nil,
                    progress: episodeProgressFor(episode.id, episodeID))
            } else {
                // No episode id to build a route from — an unrecognized/degenerate shelf projection;
                // never renders a non-tappable/dead card (see `EpisodeCard`'s sibling doc comment).
                EmptyView()
            }
        case .unknown:
            EmptyView()
        }
    }

    /// Warms the disk cover cache for this shelf's cover-bearing entities on appear. `CoverStore`
    /// dedups concurrent fetches (Task 4), so a prefetch that coincides with a card's own
    /// `CachedCoverView` load coalesces into ONE network fetch rather than two.
    private func prefetchCovers() async {
        guard let client = app.client, let connectionID = app.activeConnectionID else { return }
        let coverStore = app.coverStore
        let ids: [String] = shelf.entities.compactMap { entity in
            switch entity {
            case .book(let book): return book.id
            case .episode(let episode): return episode.id
            case .author, .unknown: return nil
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for itemID in ids {
                group.addTask {
                    let url = client.coverURL(itemID: itemID, width: 300, updatedAt: nil)
                    _ = try? await coverStore.coverData(
                        connectionID: connectionID, itemID: itemID, updatedAt: nil
                    ) {
                        try await URLSession.shared.data(from: url).0
                    }
                }
            }
        }
    }
}

/// The podcast-vs-book routing decision for a `.book`-shaped shelf entity (M1c-c Task 7) — pulled out
/// of `ShelfRow.card(for:)` into a pure, stateless, independently-testable func.
///
/// **Grounded in `podcast-personalized.json` (M1c-c Task 1's live capture):** a podcast library's
/// `recently-added` shelf entities decode as `.book` (`ShelfBookEntity`) — they carry `media`, not
/// `recentEpisode` — because they're podcast LIBRARY ITEMS, not episodes; the episode-typed shelves
/// (`continue-listening`/`newest-episodes`) decode as `.episode` instead and never reach this check.
///
/// **Fix round 2 (corrected grounding):** every `recently-added` shelf entity carries its OWN
/// top-level `mediaType` field — LIVE-VERIFIED against BOTH fixtures: `"podcast"` in
/// `podcast-personalized.json`, `"book"` in `personalized.json` (the v1 claim that shelf entities
/// carry "no mediaType of their own" was FALSE — the field was simply unmapped on `ShelfBookEntity`).
/// So the PRECISE, per-entity signal is `entityMediaType == "podcast"`; we prefer it when present.
/// Only when the entity omits it (an older/variant server, or a projection that ever drops it) do we
/// fall back to the enclosing `Shelf.type` — `"podcast"` for a podcast library's `recently-added`,
/// `"book"` for a book library's (ABS sets it to the library's own `mediaType`, per the plan source:
/// "recently-added(type = library.mediaType)"). Misrouting a podcast to `ItemDetailRoute` would open
/// the book detail page for something that isn't a book (no chapters/tracks/author-book concepts
/// apply), so this check is load-bearing, not cosmetic.
enum ShelfCardRouting {
    static func isPodcastBookEntity(entityMediaType: String?, shelfType: String) -> Bool {
        if let entityMediaType, !entityMediaType.isEmpty {
            return entityMediaType == "podcast"    // precise per-entity signal wins
        }
        return shelfType == "podcast"              // fallback: the enclosing shelf's type
    }
}
