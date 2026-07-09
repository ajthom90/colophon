import SwiftUI
import ABSKit
import LibraryCache

/// The blended local-FTS5 ⨯ server search surface (Task 10; podcast/episode buckets added Task 8).
/// `.searchable` is the native search affordance; results are a grouped `List` of `Section`s (Apple
/// Music/Podcasts search idiom): a Titles section (instant FTS, enriched in place by the server
/// `book`/`podcast` buckets — a podcast library item lands here too, marked `isPodcast`), then the
/// SERVER-ONLY sections Episodes → Series → Authors → Narrators → Genres → Tags (Episodes sits
/// right after Titles, à la Apple Podcasts "Shows then Episodes"). Tapping a title pushes its detail
/// (book or podcast, by kind); an episode row pushes `EpisodeDetailView`; a series or author pushes
/// its detail. Empty states are native (`ContentUnavailableView`).
///
/// Liquid Glass discipline (a review criterion): the ONLY glass is the system search bar / nav
/// chrome the shell and `.searchable` provide — every list row, cover, and label is OPAQUE content.
///
/// **Per-library scope:** search is per-library. If the active connection has more than one
/// library, this searches the active/first one (a note is shown); the `SearchModel` scopes BOTH
/// tiers to that library so local and server results agree.
struct SearchView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var libraries: [CachedLibrary] = []
    @State private var model: SearchModel?
    /// The library the current `model` was built for — lets `syncLibraries` rebuild only on a
    /// genuine active-library change, not on every observation tick.
    @State private var modeledLibraryID: String?

    private var activeLibrary: CachedLibrary? { libraries.first }

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $query, prompt: Text("Titles, authors, series"))
            .onChange(of: query) { _, newValue in model?.updateQuery(newValue) }
            .task(id: app.activeConnectionID) { await syncLibraries() }
            // Registered at this stack's stable root — SearchView is the unconditional root of the
            // shell's Search `NavigationStack`, so (unlike the browse views) it may self-register.
            // `.podcastDetailDestination()`/`.episodeDetailDestination()` join `.itemDetailDestination()`
            // here (Task 8) so a podcast/episode title row resolves instead of dead-ending — the same
            // macOS "register INSIDE the stack, on its root content" rule `SplitShell` documents.
            .navigationDestination(for: SeriesSummary.self) { series in
                if let library = activeLibrary { SeriesDetailView(library: library, series: series) }
            }
            .navigationDestination(for: AuthorSummary.self) { author in
                if let library = activeLibrary { AuthorDetailView(library: library, author: author) }
            }
            .itemDetailDestination()
            .podcastDetailDestination()
            .episodeDetailDestination()
    }

    @ViewBuilder
    private var content: some View {
        if let model, let library = activeLibrary {
            SearchResultsView(model: model, library: library,
                              multiLibrary: libraries.count > 1)
        } else {
            ContentUnavailableView {
                Label("Search", systemImage: "magnifyingglass")
            } description: {
                Text("Connect a library to search its titles, authors, and series.")
            }
        }
    }

    /// Observes the connection's libraries and (re)builds the `SearchModel` for the active/first
    /// one, re-running the live query against a freshly built model so a connection/library switch
    /// doesn't strand stale results.
    private func syncLibraries() async {
        guard let connectionID = app.activeConnectionID else {
            libraries = []; model = nil; modeledLibraryID = nil; return
        }
        do {
            for try await libs in app.cache.observeLibraries(connectionID: connectionID) {
                libraries = libs
                if let library = libs.first {
                    if modeledLibraryID != library.id {
                        let fresh = SearchModel(app: app, connectionID: connectionID, libraryID: library.id,
                                                 libraryMediaType: library.mediaType)
                        model = fresh
                        modeledLibraryID = library.id
                        if !query.isEmpty { fresh.updateQuery(query) }
                    }
                } else {
                    model = nil; modeledLibraryID = nil
                }
            }
        } catch {
            // A dropped observation is non-fatal to search — keep any existing model/results up.
        }
    }
}

/// The results list + native empty/loading states, driven by an observed `SearchModel`.
private struct SearchResultsView: View {
    let model: SearchModel
    let library: CachedLibrary
    let multiLibrary: Bool

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                // No query yet → a native prompt.
                ContentUnavailableView {
                    Label("Search Your Library", systemImage: "magnifyingglass")
                } description: {
                    Text("Find titles, authors, series, narrators, genres, and tags.")
                }
            } else if model.hasAnyResults {
                resultsList
            } else if model.isSearching {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Nothing local, nothing from the server → the native no-results state.
                ContentUnavailableView.search(text: model.query)
            }
        }
    }

    private var resultsList: some View {
        List {
            if !model.titles.isEmpty {
                Section {
                    ForEach(model.titles) { row in SearchTitleRow(row: row) }
                } header: {
                    Text("Titles")
                } footer: {
                    // Local results are up; the server tier is still enriching them.
                    if model.isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching the server…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if multiLibrary {
                        Text("Searching “\(library.name).” Switch libraries to search another.")
                    }
                }
            }

            if !model.episodes.isEmpty {
                Section("Episodes") {
                    ForEach(model.episodes) { row in SearchEpisodeResultRow(row: row) }
                }
            }

            if !model.series.isEmpty {
                Section("Series") {
                    ForEach(model.series) { series in
                        NavigationLink(value: series) {
                            EntityRow(name: series.name, count: series.books?.count, unit: "book")
                        }
                    }
                }
            }

            if !model.authors.isEmpty {
                Section("Authors") {
                    ForEach(model.authors) { author in
                        NavigationLink(value: author) {
                            AuthorSearchRow(library: library, author: author)
                        }
                    }
                }
            }

            if !model.narrators.isEmpty {
                Section("Narrators") {
                    ForEach(model.narrators, id: \.name) { EntityRow(name: $0.name, count: $0.numBooks, unit: "book") }
                }
            }

            if !model.genres.isEmpty {
                Section("Genres") {
                    ForEach(model.genres, id: \.name) { EntityRow(name: $0.name, count: $0.numItems, unit: "item") }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.name) { EntityRow(name: $0.name, count: $0.numItems, unit: "item") }
                }
            }
        }
    }
}

/// A compact title result row: small cover, title, author (or subtitle) — tapping pushes
/// `ItemDetailView` for a book row or `PodcastDetailView` for a podcast row (`row.isPodcast`,
/// Task 8: the deferred M1c-a Task 4 routing gap — a podcast title landed in `titles` via the
/// server `podcast` bucket must open the episode list, not dead-end into the book detail), matching
/// `CoverCard`'s same book-vs-podcast branch. The stack's `.itemDetailDestination()` /
/// `.podcastDetailDestination()` (both registered on `SearchView`) resolve the push.
private struct SearchTitleRow: View {
    let row: ItemRow

    var body: some View {
        Group {
            if row.isPodcast {
                NavigationLink(value: PodcastDetailRoute(
                    itemID: row.id, title: row.title, author: row.author ?? row.subtitle,
                    updatedAt: row.updatedAt)
                ) { rowLabel }
            } else {
                NavigationLink(value: ItemDetailRoute(
                    itemID: row.id, title: row.title, author: row.author ?? row.subtitle,
                    updatedAt: row.updatedAt, duration: row.duration)
                ) { rowLabel }
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            CachedCoverView(itemID: row.id, updatedAt: row.updatedAt)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let secondary = row.author ?? row.subtitle, !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// An episode result row: small (podcast) cover, episode title, podcast title + duration — tapping
/// pushes `EpisodeDetailView` via `EpisodeDetailRoute` (Task 8), consistent with `SearchTitleRow`
/// and `EpisodeRow` (the podcast-detail episode list). The stack's `.episodeDetailDestination()`
/// (registered on `SearchView`) resolves the push.
private struct SearchEpisodeResultRow: View {
    let row: EpisodeSearchRow

    private var metaText: String? {
        guard let duration = row.duration, let text = ItemDetailView.compactDuration(duration) else {
            return row.podcastTitle
        }
        return "\(row.podcastTitle) · \(text)"
    }

    var body: some View {
        NavigationLink(value: EpisodeDetailRoute(
            podcastItemID: row.podcastItemID, episodeID: row.episodeID,
            podcastTitle: row.podcastTitle, updatedAt: row.updatedAt)
        ) {
            HStack(spacing: 12) {
                CachedCoverView(itemID: row.podcastItemID, updatedAt: row.updatedAt)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.episodeTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let metaText {
                        Text(metaText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }
}

/// An author result row with an avatar (matches `AuthorsListView`'s row) — pushes `AuthorDetailView`.
private struct AuthorSearchRow: View {
    let library: CachedLibrary
    let author: AuthorSummary

    var body: some View {
        HStack(spacing: 12) {
            AuthorAvatarView(library: library, authorID: author.id, name: author.name,
                             imagePath: author.imagePath, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(author.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let n = author.numBooks {
                    Text("\(n) book\(n == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// A plain name + count row for the non-navigable entity sections (Series/Narrators/Genres/Tags).
private struct EntityRow: View {
    let name: String
    let count: Int?
    let unit: String

    var body: some View {
        HStack {
            Text(name)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            if let count {
                Text("\(count) \(unit)\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
