import Foundation
import ColophonShared

/// The concrete navigation a resolved deep link / Siri phrase drives (M2b Task 5), expressed with
/// the EXISTING browse routes so the shells push exactly what a `NavigationLink(value:)` would — NO
/// parallel navigator. `resume` is an ACTION (handled in `AppState`, no navigation); `search`/`home`
/// are tab/sidebar selections the shells resolve.
enum DeepLinkDestination: Equatable {
    case item(ItemDetailRoute)
    case podcast(PodcastDetailRoute)
    case episode(EpisodeDetailRoute)
    case resume
    case search(query: String?)
    case home
}

/// The cached display metadata a deep-linked item id resolves to — the ONLY app state
/// `DeepLinkRouter.destination` reads, injected as a closure so the mapping stays a PURE,
/// unit-testable function (asserted against canned inputs, with no live cache / socket / player).
struct DeepLinkItemInfo: Equatable {
    var title: String
    var author: String?
    var updatedAt: Int?
    var duration: Double?
    /// Whether the item is a PODCAST (routes to `PodcastDetailRoute` instead of `ItemDetailRoute`).
    var isPodcast: Bool
}

/// The PURE deep-link → destination decision + resume-target selection (M2b Task 5). Kept OUT of
/// `AppState` so each (link, item-kind) → route mapping is unit-tested without a live cache: the
/// parse (`ColophonDeepLink.init?(url:)`, in ColophonShared) and this dispatch are the whole
/// URL→route pipeline the widget / Live Activity / Spotlight deep links flow through.
enum DeepLinkRouter {
    /// Map an already-parsed `ColophonDeepLink` to the destination the shell navigates to, reusing the
    /// existing routes:
    ///   - `resume` → `.resume` (the app plays the top continue-listening item; no push).
    ///   - `item` with an `episodeID` → `EpisodeDetailRoute` (an episode is always a podcast episode).
    ///   - `item` the cache says is a podcast → `PodcastDetailRoute`.
    ///   - `item` otherwise → `ItemDetailRoute` (also the fallback for an UNCACHED item — seeded with
    ///     the id, since `ItemDetailView` fetches the rest).
    static func destination(
        for link: ColophonDeepLink,
        itemInfo: (_ itemID: String) -> DeepLinkItemInfo?
    ) -> DeepLinkDestination {
        switch link {
        case .resume:
            return .resume
        case let .item(id, episodeID):
            let info = itemInfo(id)
            if let episodeID, !episodeID.isEmpty {
                return .episode(EpisodeDetailRoute(
                    podcastItemID: id, episodeID: episodeID,
                    podcastTitle: info?.title ?? "", updatedAt: info?.updatedAt))
            }
            if info?.isPodcast == true {
                return .podcast(PodcastDetailRoute(
                    itemID: id, title: info?.title ?? id, author: info?.author, updatedAt: info?.updatedAt))
            }
            return .item(ItemDetailRoute(
                itemID: id, title: info?.title ?? id, author: info?.author,
                updatedAt: info?.updatedAt, duration: info?.duration))
        }
    }

    /// The resume target for `colophon://resume` / `ResumeIntent` — the TOP continue-listening entry
    /// (the app publishes the shelf most-recent-first, matching the widget's order), or nil when the
    /// shelf is empty.
    static func resumeTarget(in snapshot: ContinueListeningSnapshot?) -> ContinueListeningSnapshot.Entry? {
        snapshot?.entries.first
    }
}
