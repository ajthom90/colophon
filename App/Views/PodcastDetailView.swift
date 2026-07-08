import SwiftUI
import ABSKit
import LibraryCache

/// The value pushed onto a browse stack to open `PodcastDetailView` — the podcast counterpart to
/// `ItemDetailRoute`. A podcast library's grid card carries a `mediaType == "podcast"` item, so
/// `CoverCard` pushes THIS route (not `ItemDetailRoute`) for it; the destination is registered at
/// each browse stack's stable root via `.podcastDetailDestination()` (see `SplitShell`/`PhoneShell`),
/// exactly like `.itemDetailDestination()`. `Hashable` so it rides the standard
/// `NavigationLink(value:)` + `navigationDestination(for:)` pattern.
struct PodcastDetailRoute: Hashable {
    let itemID: String
    let title: String
    let author: String?
    let updatedAt: Int?
}

extension View {
    /// Registers `PodcastDetailRoute` on the enclosing `NavigationStack`. Call once per stack, at its
    /// STABLE root — and, in a `NavigationSplitView` detail column, on the ROOT CONTENT view INSIDE
    /// the column's `NavigationStack` (never on the stack value itself, or a card tap dead-ends with
    /// "There is no next column after the detail column"; see `SplitShell`'s nav-destination note).
    func podcastDetailDestination() -> some View {
        navigationDestination(for: PodcastDetailRoute.self) { PodcastDetailView(route: $0) }
    }
}

/// How the episode list is ordered — surfaced via the toolbar sort `Menu`. `.season` additionally
/// forces season `Section`s even for a single-season feed.
private enum EpisodeSort: String, CaseIterable, Identifiable {
    case newest, oldest, season
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .season: return "By Season"
        }
    }
}

/// The native podcast page, à la Apple Podcasts. OPAQUE content throughout (cover, header, HTML
/// description, episode rows); the only Liquid Glass is the system toolbar the nav chrome provides
/// (which hosts the sort `Menu`). There is intentionally no `.glassProminent` primary yet — a
/// prominent Play lands with episode playback (M1c-c Task 5/6); adding a non-functional one now
/// would be a dead control.
///
/// Data flow mirrors the browse/detail surfaces: instant paint from the cache
/// (`observeEpisodes` for the list, live per-episode `observeProgress`), then a single background
/// `AppState.refreshPodcastEpisodes` round trip that both reconciles episodes into the v2
/// `cachedEpisode` table AND returns the `PodcastDetail` used to fill the header's HTML description.
///
/// Episodes group into a `Section` per **season** when more than one season is present (or when the
/// user picks "By Season"); otherwise a single flat "Episodes" section. Per-episode finished /
/// in-progress state comes from the 3-part-PK `cachedProgress` join (`episodeID` populated).
struct PodcastDetailView: View {
    @Environment(AppState.self) private var app
    let route: PodcastDetailRoute

    /// Episodes from the cache observation (instant paint + live repaint on each reconcile).
    @State private var episodes: [CachedEpisode] = []
    /// This item's per-episode progress, keyed by `episodeID` (book-style empty-episode rows excluded).
    @State private var progressByEpisode: [String: CachedProgress] = [:]
    /// The fetched detail — the ONLY source of the podcast's HTML description (podcast descriptions
    /// aren't cached; books' are). Nil until the background refresh lands.
    @State private var detail: PodcastDetail?
    @State private var sort: EpisodeSort = .newest
    @State private var descriptionExpanded = false
    /// The HTML description parsed to an `AttributedString` ONCE (see `HTMLText`), on the main actor.
    @State private var formattedDescription: AttributedString?
    @State private var state: LoadState = .idle

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    var body: some View {
        List {
            Section {
                header.listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { sortMenu }
        .task(id: route.itemID) { await observeEpisodes() }
        .task(id: route.itemID) { await observeProgress() }
        .task(id: route.itemID) { await refresh() }
        .task(id: displayDescription) {
            // Parse the HTML description ONCE per value on the main actor (expensive), so the render
            // just reads this @State — never re-parses per `body`.
            if let description = displayDescription, !description.isEmpty {
                formattedDescription = HTMLText.attributed(fromHTML: description)
            } else {
                formattedDescription = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                CachedCoverView(itemID: route.itemID, updatedAt: route.updatedAt)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    if let author = displayAuthor, !author.isEmpty {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let genres = detail?.media.metadata.genres?.filter({ !$0.isEmpty }), !genres.isEmpty {
                        Text(genres.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fontDesign(.default)
                    }
                }
                Spacer(minLength: 0)
            }

            if let description = displayDescription, !description.isEmpty {
                descriptionBlock(description)
            }
        }
        .padding(.vertical, 8)
    }

    private func descriptionBlock(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // HTML rendered as formatted text (see `HTMLText`, safe + network-free); the fallback
            // runs the SAME synchronous strip for the frame before the parse task populates — never
            // raw tags.
            Text(formattedDescription ?? HTMLText.attributed(fromHTML: description))
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 4)
            Button(descriptionExpanded ? "Show Less" : "More") {
                withAnimation { descriptionExpanded.toggle() }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    // MARK: - Episode list

    @ViewBuilder
    private var content: some View {
        if episodes.isEmpty {
            statusRow.listRowSeparator(.hidden)
        } else if shouldGroupBySeason {
            ForEach(groupedSections) { section in
                Section(section.title) {
                    ForEach(section.episodes) { episodeRow($0) }
                }
            }
        } else {
            Section("Episodes") {
                ForEach(sortedEpisodes(episodes)) { episodeRow($0) }
            }
        }
    }

    private func episodeRow(_ episode: CachedEpisode) -> some View {
        EpisodeRow(
            episode: episode,
            progress: progressByEpisode[episode.episodeID],
            onPlay: { startEpisodePlayback(episode) })
    }

    /// The loading / empty / error state, shown in place of the episode sections when there are no
    /// cached episodes to paint — native `ProgressView` / `ContentUnavailableView`.
    @ViewBuilder
    private var statusRow: some View {
        Group {
            switch state {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load episodes", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message.isEmpty || message == "offline"
                         ? "Episodes are unavailable offline."
                         : message)
                } actions: {
                    Button("Retry") { Task { await refresh() } }
                }
            case .idle, .loading:
                ProgressView().controlSize(.large)
            case .loaded:
                ContentUnavailableView {
                    Label("No Episodes", systemImage: "waveform")
                } description: {
                    Text("This podcast has no episodes yet.")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(EpisodeSort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    // MARK: - Grouping / sorting

    /// Distinct non-empty season values, in first-seen order.
    private var seasons: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for episode in episodes {
            if let season = episode.season, !season.isEmpty, seen.insert(season).inserted {
                order.append(season)
            }
        }
        return order
    }

    /// Group into `Section`s when the feed spans more than one season, or when the user explicitly
    /// sorts by season. A single-season (or season-less) feed under Newest/Oldest stays a flat list.
    private var shouldGroupBySeason: Bool {
        sort == .season || seasons.count > 1
    }

    /// The chosen flat ordering: newest/oldest by `publishedAt` (NULLs sort last either way); "By
    /// Season" (used within a section) by numeric episode number, then `publishedAt` ascending.
    private func sortedEpisodes(_ list: [CachedEpisode]) -> [CachedEpisode] {
        switch sort {
        case .newest:
            return list.sorted { ($0.publishedAt ?? .min) > ($1.publishedAt ?? .min) }
        case .oldest:
            return list.sorted { ($0.publishedAt ?? .max) < ($1.publishedAt ?? .max) }
        case .season:
            return list.sorted { lhs, rhs in
                let ln = Int(lhs.episode ?? "") ?? .max
                let rn = Int(rhs.episode ?? "") ?? .max
                if ln != rn { return ln < rn }
                return (lhs.publishedAt ?? .max) < (rhs.publishedAt ?? .max)
            }
        }
    }

    private struct EpisodeSection: Identifiable {
        let id: String
        let title: String
        let episodes: [CachedEpisode]
    }

    /// Episodes grouped by season. Season sections are ordered ascending for Oldest/By-Season and
    /// descending for Newest; season-less episodes collect into a trailing "Episodes" section. Each
    /// section's episodes use the same `sortedEpisodes` order as the flat list.
    private var groupedSections: [EpisodeSection] {
        let grouped = Dictionary(grouping: episodes.filter { !($0.season ?? "").isEmpty }) { $0.season ?? "" }
        let ascending = (sort != .newest)
        let keys = grouped.keys.sorted { lhs, rhs in
            let ln = Int(lhs) ?? .max
            let rn = Int(rhs) ?? .max
            return ascending ? (ln < rn) : (ln > rn)
        }
        var sections = keys.map { key in
            EpisodeSection(id: key, title: "Season \(key)", episodes: sortedEpisodes(grouped[key] ?? []))
        }
        let seasonless = episodes.filter { ($0.season ?? "").isEmpty }
        if !seasonless.isEmpty {
            sections.append(EpisodeSection(id: "", title: "Episodes", episodes: sortedEpisodes(seasonless)))
        }
        return sections
    }

    // MARK: - Episode playback call site (M1c-c Task 5)

    /// THE single episode-play entry point — the row tap and both context-menu actions funnel here.
    ///
    /// ⚠️ M1c-c Task 5 points this at the shared player via `AppState.startPlayback` extended for an
    /// `episodeId:` path (see the plan's Task 5). Until then it is intentionally INERT — it does NOT
    /// fake playback (no partial/silent audio path); it only records the intended episode so the
    /// wiring point is unambiguous. Do NOT add a parallel playback path elsewhere; extend this one.
    private func startEpisodePlayback(_ episode: CachedEpisode) {
        // TODO(M1c-c Task 5): await app.startPlayback(itemID: route.itemID, episodeId: episode.episodeID)
        NSLog("[Colophon] Episode playback pending (Task 5): item=%@ episode=%@", route.itemID, episode.episodeID)
    }

    // MARK: - Derived display values

    private var displayTitle: String { detail?.media.metadata.title ?? route.title }
    private var displayAuthor: String? { detail?.media.metadata.author ?? route.author }
    private var displayDescription: String? { detail?.media.metadata.description }

    // MARK: - Data

    private func observeEpisodes() async {
        episodes = []
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await value in app.cache.observeEpisodes(connectionID: connectionID, itemID: route.itemID) {
                episodes = value
            }
        } catch {
            // Best-effort instant paint; the background refresh below still drives the list.
        }
    }

    private func observeProgress() async {
        progressByEpisode = [:]
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeProgress(connectionID: connectionID) {
                progressByEpisode = Dictionary(
                    rows.filter { $0.itemID == route.itemID && !$0.episodeID.isEmpty }
                        .map { ($0.episodeID, $0) },
                    uniquingKeysWith: { $0.lastUpdate >= $1.lastUpdate ? $0 : $1 })
            }
        } catch {
            // Best-effort live finished/in-progress state; rows still render without it.
        }
    }

    /// One background round trip (via `AppState.refreshPodcastEpisodes`): reconciles episodes into
    /// the cache (repainting the list through `observeEpisodes`) AND returns the detail for the
    /// header description. Instant paint already came from the cache observation, so a failure with
    /// cached episodes present is non-fatal.
    private func refresh() async {
        guard app.client != nil else {
            state = episodes.isEmpty ? .failed("offline") : .loaded
            return
        }
        if episodes.isEmpty { state = .loading }
        do {
            detail = try await app.refreshPodcastEpisodes(itemID: route.itemID)
            state = .loaded
        } catch {
            state = episodes.isEmpty
                ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : .loaded
        }
    }
}
