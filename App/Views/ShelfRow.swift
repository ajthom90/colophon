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
                isPodcast: ShelfCardRouting.isPodcastBookEntity(shelfType: shelf.type))
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
/// Neither `ShelfBookEntity` nor `ShelfEntityMedia`/`ShelfEntityMetadata` carries a `mediaType` field
/// of its own (verified against both the book and podcast fixtures — the shelf projection just omits
/// it), so the entity's OWN shape can't distinguish a podcast from a book. The one signal that DOES
/// distinguish them is the enclosing `Shelf.type`: `"book"` for a book library's `recently-added`
/// (`personalized.json`) vs. `"podcast"` for a podcast library's (`podcast-personalized.json`) — ABS
/// sets the shelf `type` to the library's own `mediaType` for this shelf (per the plan's source
/// reference: "recently-added(type = library.mediaType)"). Misrouting a podcast to `ItemDetailRoute`
/// would open the book detail page for something that isn't a book (no chapters/tracks/author-book
/// concepts apply), so this check is load-bearing, not cosmetic.
enum ShelfCardRouting {
    static func isPodcastBookEntity(shelfType: String) -> Bool {
        shelfType == "podcast"
    }
}
