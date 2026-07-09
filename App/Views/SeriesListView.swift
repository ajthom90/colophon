import SwiftUI
import ABSKit
import LibraryCache

/// The series browse surface: a native `List` from `GET /api/libraries/:id/series?limit=` — note
/// `limit` is REQUIRED to get rows back (the server accepts an omitted `limit` with HTTP 200, but
/// `limit:0` yields an empty `results` — verified live/Task 5), so this always passes a large
/// explicit limit. Each row shows the series name + "N books"; tapping pushes `SeriesDetailView`.
/// The seeded dev library has NO series, so the common case here is the native "No Series" empty
/// state below, not the list.
///
/// **The caller registers `.navigationDestination(for: SeriesSummary.self)`, not this view** — same
/// reasoning as `AuthorsListView`'s doc comment: this view is reached through `PhoneShell`'s
/// `browseMode`-switched (conditionally-mounted) root as well as `SplitShell`'s stable dedicated
/// stack, and a destination self-registered on the conditionally-mounted copy resets the parent's
/// `@State` on pop. The registration lives at each call site's stable root instead.
///
/// Liquid Glass discipline: the ONLY glass is the system nav-bar/sidebar chrome the shell provides
/// — the list rows and text are OPAQUE content.
struct SeriesListView: View {
    @Environment(AppState.self) private var app
    let library: CachedLibrary

    /// Comfortably above any real library's series count; the server has no upper bound on this
    /// param, and a 1-page fetch keeps this view simple (no pager, matching `AuthorsListView`).
    private static let fetchLimit = 1000

    @State private var series: [SeriesSummary] = []
    @State private var state: LoadState = .idle

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    var body: some View {
        content
            .navigationTitle("Series")
            .task(id: library.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if series.isEmpty {
            switch state {
            case .idle, .loading:
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load series", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            case .loaded:
                // The proven-live case for this dev fixture: zero series, rendered as a native
                // empty state rather than a blank screen (this task's E2E screenshots it).
                ContentUnavailableView {
                    Label("No Series", systemImage: "square.stack")
                } description: {
                    Text("This library has no series yet.")
                }
            }
        } else {
            List(series) { series in
                NavigationLink(value: series) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(series.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(bookCountLabel(series))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func bookCountLabel(_ series: SeriesSummary) -> String {
        let n = series.books?.count ?? 0
        return "\(n) book\(n == 1 ? "" : "s")"
    }

    private func load() async {
        if series.isEmpty { state = .loading }
        do {
            // `browseFetch` applies the shared `!app.isOffline` fast-path (M2a Task 7 pattern,
            // extended per final review #3): a `nil` result means the server is KNOWN-unreachable
            // (`client` is still NON-nil offline — valid tokens, server down, link up — so a bare
            // client-nil guard would fall through and hang a live `series` request to the transport
            // timeout). Degrade to the cached/offline state instead of spinning.
            guard let fetched = try await app.browseFetch({
                try await $0.series(libraryID: library.id, limit: Self.fetchLimit)
            }) else {
                if series.isEmpty { state = .failed("You're offline — series need a live connection.") }
                return
            }
            series = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            state = .loaded
        } catch {
            if series.isEmpty {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

/// A series' detail: its books in an `ItemsCoverGrid`. **Deviation from the plan's sketch** (which
/// named `GET /api/series/:id` as the books source): source-checked against ABS (`SeriesController.
/// findOne` / `LibraryController.getSeriesForLibrary`) this task, and BOTH return only
/// `Series.toOldJSON()` (id/name/description/timestamps) plus optional `progress`/`rssFeed` —
/// **no books array at all**. The only endpoint that actually embeds a series' books is the LIST
/// endpoint this screen came from (`GET /api/libraries/:id/series?limit=` → `seriesFilters.
/// getFilteredSeries`, which maps `books` via `LibraryItem.toOldJSONMinified()` — the same shape as
/// `LibraryItemSummary`), so `SeriesDetailView` reuses the `books` already embedded on the
/// `SeriesSummary` passed in from `SeriesListView` instead of an extra (books-less) round trip.
///
/// Unexercised live this milestone: the seeded dev library has zero series, so there is no real
/// series to open this view against — it renders from `series.books` alone and, per its own
/// contract, must not crash on an empty/nil array (verified by the empty-state branch below).
struct SeriesDetailView: View {
    @Environment(AppState.self) private var app
    let library: CachedLibrary
    let series: SeriesSummary

    @State private var progressByItem: [String: CachedProgress] = [:]

    private var books: [LibraryItemSummary] { series.books ?? [] }

    var body: some View {
        ScrollView {
            if books.isEmpty {
                ContentUnavailableView {
                    Label("No Books", systemImage: "book")
                } description: {
                    Text("No books found for this series.")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ItemsCoverGrid(items: books, progressByItem: progressByItem)
                    .padding(.top, 8)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(series.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: app.activeConnectionID) { await observeProgress() }
    }

    private func observeProgress() async {
        progressByItem = [:]
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeProgress(connectionID: connectionID) {
                progressByItem = rows.indexedByItem()
            }
        } catch {
            // Best-effort live pills; the grid still paints without progress.
        }
    }
}
