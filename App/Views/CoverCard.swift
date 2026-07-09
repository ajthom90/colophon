import SwiftUI
import LibraryCache

/// One book card in a home shelf — an OPAQUE content card (never glass): the item's cover, a
/// serif title (2-line clamp), the author (1-line secondary), and a subtle progress affordance
/// shown ONLY when the item has in-progress `CachedProgress` (0 < fraction < 1, not finished):
/// a thin determinate bar hugging the cover's bottom edge (the Apple Books "currently listening"
/// idiom) plus a small tinted percentage pill. Progress is JOINED from `CachedProgress`
/// (`me()`/socket), NOT the shelf entity — shelf entities carry no progress (verified live). The
/// duration for the fraction is a caller-supplied duration source (progress rows store
/// `currentTime`, not duration): a shelf card passes the shelf entity's `media.duration`, and the
/// LIBRARY GRID passes `CachedItem.duration` (always present on the grid row) — the Task 7-review
/// fix so grid pills render, since the shelf-entity duration isn't available there. Tapping pushes
/// `ItemDetailView` (via `ItemDetailRoute` — the Play/Resume action lives in the detail); the
/// destination is registered at each browse stack's stable root (`.itemDetailDestination()`).
struct CoverCard: View {
    @Environment(AppState.self) private var app
    let itemID: String
    let updatedAt: Int?
    let title: String
    let author: String?
    /// The duration source for the progress fraction — the shelf entity's `media.duration` (shelf
    /// cards) or `CachedItem.duration` (library grid). Needed to turn a `currentTime` into a fraction.
    let duration: Double?
    /// Joined from the cache (nil when the server reports no progress for this item).
    let progress: CachedProgress?
    /// True for a `mediaType == "podcast"` item (the library grid passes `library.mediaType ==
    /// "podcast"`). A podcast card pushes `PodcastDetailRoute` → `PodcastDetailView` (the episode
    /// list), NOT the book `ItemDetailView`, and drops the book-only queue context menu.
    var isPodcast: Bool = false
    /// This item's own `CachedDownload.state` (M2a Task 8), or `nil` — feeds the compact, opaque
    /// `DownloadStateBadge` overlay so a user browsing sees what's offline-available at a glance
    /// (only a book has a whole-item download; a podcast's episodes download individually, so a
    /// podcast card's caller has nothing meaningful to pass and the badge never shows for one).
    var downloadState: String? = nil

    static let width: CGFloat = 150

    /// The listened fraction, but ONLY when it's a meaningful in-progress value (0 < f < 1 and not
    /// finished) — otherwise nil so no bar/pill renders on an untouched or completed item.
    private var fraction: Double? {
        guard let progress, !progress.isFinished,
              let duration, duration > 0 else { return nil }
        let f = progress.currentTime / duration
        guard f > 0, f < 1 else { return nil }
        return f
    }

    var body: some View {
        // A podcast card pushes `PodcastDetailRoute` (→ the episode list); a book card pushes
        // `ItemDetailRoute` (→ the book page). `NavigationLink(value:)` is resolved by the value's
        // concrete type, so the two routes must be distinct branches (an erased `AnyHashable` value
        // wouldn't match either `navigationDestination(for:)`), sharing one `cardLabel`.
        Group {
            if isPodcast {
                NavigationLink(value: PodcastDetailRoute(
                    itemID: itemID, title: title, author: author, updatedAt: updatedAt)
                ) { cardLabel }
            } else {
                NavigationLink(value: ItemDetailRoute(
                    itemID: itemID, title: title, author: author, updatedAt: updatedAt, duration: duration)
                ) { cardLabel }
                .contextMenu {
                    // Up-next queue affordances (Task 8) — native context-menu actions on a book
                    // browse card. Enabled only while a book is playing (there's a "current book" to
                    // queue after). The guard is per-BUTTON, not on the card, so it never disables
                    // tap-through to the detail. Not offered for podcasts (episode queueing is Task 5).
                    Button {
                        app.playNext(itemID: itemID, title: title, author: author)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(app.nowPlayingItemID == nil)
                    Button {
                        app.addToQueue(itemID: itemID, title: title, author: author)
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                    .disabled(app.nowPlayingItemID == nil)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedCoverView(itemID: itemID, updatedAt: updatedAt)
                .frame(width: Self.width, height: Self.width)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    DownloadStateBadge(state: downloadState).padding(6)
                }
                .overlay(alignment: .bottom) {
                    if let fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }

            // Serif comes from the app-wide `.fontDesign` (root typeface toggle) — per the
            // ColophonApp convention, per-view `.fontDesign(.serif)` is NOT reintroduced here.
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            if let author, !author.isEmpty {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let fraction {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.tint))
                    .accessibilityLabel("\(Int((fraction * 100).rounded())) percent listened")
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }
}

/// An author entity card in the "Newest Authors" shelf — an avatar circle (initials placeholder;
/// real author artwork via `/api/authors/:id/image` is Task 9's authors browse) plus the name.
/// Not tappable-to-play (there's nothing to play); author detail is Task 9.
struct AuthorCard: View {
    let name: String

    static let width: CGFloat = 110

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(.quaternary)
                .frame(width: 90, height: 90)
                .overlay {
                    Text(initials)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    if initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }

            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: Self.width)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

/// A podcast-episode shelf entity card (continue-listening / newest-episodes / listen-again) —
/// M1c-c Task 7 REPLACES the M1c-a `EpisodeStubCard` with a real, tappable card, now that the
/// podcast dev fixture (Task 1) and episode detail page (Task 6) both exist to render/route into.
/// Renders the shared podcast cover (an episode carries no distinct artwork of its own — same
/// convention as `EpisodeDetailView`'s header, which shows the show's art on an episode page), the
/// episode title (2-line clamp, matching `CoverCard`'s title treatment), the podcast title as a
/// secondary caption (in place of `CoverCard`'s author line), and — MATCHING `CoverCard` exactly —
/// an in-progress bar hugging the cover's bottom edge + a percentage pill, shown ONLY when this
/// episode has a meaningful 0 < fraction < 1 (not finished, duration known). Progress is the
/// caller-resolved `progress` param (from `ShelfRow.episodeProgressFor`'s `(itemID, episodeID)` — see
/// `LibraryCache`'s `indexedByItemAndEpisode()`), never a collapsed "best row for this item" lookup,
/// so a podcast with several episodes shows each card's OWN progress, not a sibling's. Tapping pushes
/// `EpisodeDetailRoute` (Play/Resume lives on the detail page, per Task 6's row-tap convention) — the
/// destination must be registered wherever this card can be reached (`HomeView` self-registers it
/// alongside `.podcastDetailDestination()`; the Library stacks already did in Tasks 4/6).
struct EpisodeCard: View {
    let podcastItemID: String
    let episodeID: String
    let title: String
    let podcastTitle: String
    /// The episode's duration — the caller passes `recentEpisode.effectiveDuration` (the shelf
    /// entity's top-level `duration`, falling back to the nested `audioFile.duration` when the
    /// top-level field is `null`, which Task 1 verified it reliably is; `audioFile.duration` is
    /// re-verified LIVE, M1c-c Task 7, to carry the real value instead). If somehow neither is
    /// present, the fraction/pill below just doesn't render — exactly like `CoverCard` with an
    /// unknown duration (never a crash or a bogus 0%/100% pill).
    let duration: Double?
    let updatedAt: Int?
    /// This episode's OWN `cachedProgress` row (nil = untouched). Resolved by the caller via the
    /// 3-part `(itemID, episodeID)` key — NOT `CoverCard`'s item-collapsed lookup, which would return
    /// the wrong row for a podcast item that has several episodes sharing one `itemID`.
    let progress: CachedProgress?
    /// This EPISODE's own `CachedDownload.state` (M2a Task 8), or `nil` — resolved by the caller via
    /// the same `(itemID, episodeID)` key as `progress` (a podcast's episodes download individually,
    /// so this must never collapse to the item-level lookup `CoverCard` uses for a book).
    var downloadState: String? = nil

    static let width: CGFloat = CoverCard.width

    /// The listened fraction — ONLY when meaningfully in-progress (0 < f < 1, not finished) — the
    /// identical guard `CoverCard.fraction` uses, so the two card kinds render pills identically.
    private var fraction: Double? {
        guard let progress, !progress.isFinished,
              let duration, duration > 0 else { return nil }
        let f = progress.currentTime / duration
        guard f > 0, f < 1 else { return nil }
        return f
    }

    var body: some View {
        NavigationLink(value: EpisodeDetailRoute(
            podcastItemID: podcastItemID, episodeID: episodeID,
            podcastTitle: podcastTitle, updatedAt: updatedAt)
        ) {
            cardLabel
        }
        .buttonStyle(.plain)
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedCoverView(itemID: podcastItemID, updatedAt: updatedAt)
                .frame(width: Self.width, height: Self.width)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    DownloadStateBadge(state: downloadState).padding(6)
                }
                .overlay(alignment: .bottom) {
                    if let fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            Text(podcastTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let fraction {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.tint))
                    .accessibilityLabel("\(Int((fraction * 100).rounded())) percent listened")
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }
}
