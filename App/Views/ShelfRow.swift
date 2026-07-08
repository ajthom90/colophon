import SwiftUI
import ABSKit
import LibraryCache

/// One personalized-shelf row: a plain, OPAQUE section header (the shelf's `label`, HIG section
/// styling — never glass) above a horizontally-scrolling `LazyHStack` of cards, `.viewAligned` so
/// swipes settle card-to-card like Apple Music / Books. The card kind is chosen per entity
/// (book → `CoverCard`, author → `AuthorCard`, episode → `EpisodeStubCard`). Progress for book
/// cards is resolved via the injected `progressFor` lookup (fed by the home view's live
/// `CachedProgress` observation), so pills update without a shelf refetch.
struct ShelfRow: View {
    @Environment(AppState.self) private var app
    let shelf: Shelf
    let progressFor: (String) -> CachedProgress?

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
                author: book.media.metadata.authorName,
                duration: book.media.duration,
                progress: progressFor(book.id))
        case .author(let author):
            AuthorCard(name: author.name)
        case .episode(let episode):
            EpisodeStubCard(
                itemID: episode.id ?? "",
                title: episode.recentEpisode?.title ?? episode.media?.metadata.title ?? "Episode")
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
