import Testing
import Foundation
import ColophonShared
import ABSKit
import ABSKitTestSupport
@testable import Colophon

/// The PURE URL→route pipeline (M2b Task 5): `ColophonDeepLink.init?(url:)` (ColophonShared, tested
/// there) + `DeepLinkRouter.destination` (here). Each `colophon://` URL maps to the right existing
/// route with no live cache — the item-kind lookup is injected as a closure. Plus the resume-target
/// selection and `AppState`'s deep-link dispatch (sets `pendingNavigation`).
@MainActor
struct DeepLinkRoutingTests {
    private func link(_ string: String) -> ColophonDeepLink {
        ColophonDeepLink(url: URL(string: string)!)!
    }

    // MARK: - destination mapping (pure)

    @Test func itemLinkRoutesToBookDetail() {
        let dest = DeepLinkRouter.destination(for: link("colophon://item/book1")) { _ in
            DeepLinkItemInfo(title: "A Book", author: "Author", updatedAt: 7, duration: 100, isPodcast: false)
        }
        #expect(dest == .item(ItemDetailRoute(
            itemID: "book1", title: "A Book", author: "Author", updatedAt: 7, duration: 100)))
    }

    @Test func podcastItemLinkRoutesToPodcastDetail() {
        let dest = DeepLinkRouter.destination(for: link("colophon://item/pod1")) { _ in
            DeepLinkItemInfo(title: "Show", author: "Host", updatedAt: nil, duration: nil, isPodcast: true)
        }
        #expect(dest == .podcast(PodcastDetailRoute(
            itemID: "pod1", title: "Show", author: "Host", updatedAt: nil)))
    }

    @Test func episodeLinkRoutesToEpisodeDetail() {
        let dest = DeepLinkRouter.destination(for: link("colophon://item/pod1?episode=ep9")) { _ in
            DeepLinkItemInfo(title: "Show", author: "Host", updatedAt: 3, duration: nil, isPodcast: true)
        }
        #expect(dest == .episode(EpisodeDetailRoute(
            podcastItemID: "pod1", episodeID: "ep9", podcastTitle: "Show", updatedAt: 3)))
    }

    /// An UNCACHED item (lookup returns nil) still routes — to the book detail, seeded with the id
    /// (ItemDetailView fetches the rest). This is the widget/Spotlight "item I haven't opened" case.
    @Test func uncachedItemFallsBackToBookDetailSeededWithID() {
        let dest = DeepLinkRouter.destination(for: link("colophon://item/unknown")) { _ in nil }
        #expect(dest == .item(ItemDetailRoute(
            itemID: "unknown", title: "unknown", author: nil, updatedAt: nil, duration: nil)))
    }

    @Test func resumeLinkRoutesToResume() {
        let dest = DeepLinkRouter.destination(for: link("colophon://resume")) { _ in nil }
        #expect(dest == .resume)
    }

    // MARK: - resume-target selection (pure)

    @Test func resumeTargetIsTopContinueListeningEntry() {
        let snapshot = ContinueListeningSnapshot(entries: [
            .init(itemID: "top", title: "Top", author: "A", progress: 0.3),
            .init(itemID: "second", episodeID: "e2", title: "Second", author: "B", progress: 0.1),
        ])
        #expect(DeepLinkRouter.resumeTarget(in: snapshot)?.itemID == "top")
        #expect(DeepLinkRouter.resumeTarget(in: ContinueListeningSnapshot(entries: [])) == nil)
        #expect(DeepLinkRouter.resumeTarget(in: nil) == nil)
    }

    // MARK: - AppState dispatch

    private func makeApp() -> AppState {
        AppState(
            transportProvider: { MockTransport() },
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            socketFactory: { _, _ in FakeSocket() },
            tokenStore: InMemoryTokenStore(),
            downloadManagerProvider: { FakeDownloadManaging() })
    }

    /// `handleDeepLink` of an item URL (no active connection → uncached) sets a `pendingNavigation`
    /// the shells consume; a bogus/foreign URL is ignored.
    @Test func handleDeepLinkSetsPendingNavigation() {
        let app = makeApp()
        app.handleDeepLink(URL(string: "colophon://item/xyz")!)
        #expect(app.pendingNavigation == .item(ItemDetailRoute(
            itemID: "xyz", title: "xyz", author: nil, updatedAt: nil, duration: nil)))

        app.consumePendingNavigation()
        #expect(app.pendingNavigation == nil)

        // A non-colophon URL (e.g. an OAuth callback shape) is silently ignored.
        app.handleDeepLink(URL(string: "https://example.com/x")!)
        #expect(app.pendingNavigation == nil)
    }

    /// The Siri "Search Colophon <query>" action seeds both the query + a `.search` navigation; a
    /// blank query just opens Search.
    @Test func requestSearchSeedsQueryAndNavigation() {
        let app = makeApp()
        app.requestSearch(query: "dune")
        #expect(app.pendingSearchQuery == "dune")
        #expect(app.pendingNavigation == .search(query: "dune"))

        app.requestSearch(query: "   ")
        #expect(app.pendingSearchQuery == nil)
        #expect(app.pendingNavigation == .search(query: nil))
    }
}
