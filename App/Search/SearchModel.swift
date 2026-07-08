import Foundation
import ABSKit
import LibraryCache

/// One title row in the blended search results — the merge unit of the local FTS5 tier and the
/// server `book` bucket. `id` is the `libraryItem.id`, the dedup key: a server row REPLACES the
/// FTS placeholder with the same id (richer), while an FTS-only row the server didn't return stays
/// (offline), flagged `isServerEnriched == false`.
struct ItemRow: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var author: String?
    var subtitle: String?
    var duration: Double?
    /// Cover cache-buster (`ts=`), present on FTS rows (`CachedItem.updatedAt`) but absent on the
    /// search endpoint's item shape — the merge carries the FTS value over onto the server row.
    var updatedAt: Int?
    /// `false` for an FTS-only (offline) placeholder the server hasn't enriched; `true` once a
    /// server `book`-bucket hit has replaced it.
    var isServerEnriched: Bool

    init(cachedItem item: CachedItem) {
        id = item.id
        title = item.title
        author = item.authorName
        subtitle = item.subtitle
        duration = item.duration
        updatedAt = item.updatedAt
        isServerEnriched = false
    }

    init(hit: SearchBookHit) {
        let li = hit.libraryItem
        id = li.id
        title = li.media.metadata.title ?? "Untitled"
        author = li.media.metadata.authorName
        subtitle = li.media.metadata.subtitle
        duration = li.media.duration
        updatedAt = nil
        isServerEnriched = true
    }
}

/// The result sections, in the canonical display order: Titles → Series → Authors → Narrators →
/// Genres → Tags. `SearchModel.populatedSections` yields exactly the non-empty ones in this order,
/// so both `SearchView` and the ordering test read the order from one source.
enum SearchSection: String, CaseIterable, Hashable, Sendable {
    case titles, series, authors, narrators, genres, tags
}

/// The blended local-FTS5 ⨯ server search core. `@Observable` + `@MainActor`, driven by
/// `SearchView`'s `.searchable` query through `updateQuery(_:)`. Dependencies are injected as
/// closures — a local-FTS fn and a server-search fn — so the whole debounce / cancel / merge
/// behaviour is unit-testable against fakes with no network, no database, and no real sleeps.
///
/// Behaviour (verified search-stream reference):
///  - **Instant local tier:** every query change immediately runs the FTS5 fn and paints `titles`
///    (~5 ms) — no waiting on the server.
///  - **Debounced server tier:** after `debounceInterval` (default 275 ms) and only for queries of
///    at least `minimumServerQueryLength` (2) characters, calls the server fn. The server 400s on
///    an empty/1-char `q` (verified), so that request is NEVER made. A newer query cancels the
///    in-flight task; a superseded server result is discarded (`Task.isCancelled`).
///  - **Merge:** server `book`-bucket rows replace/enrich the matching FTS placeholder BY id
///    (one row per id, server wins); FTS-only rows stay. Entity buckets (Series/Authors/Narrators/
///    Genres/Tags) are SERVER-ONLY — cleared on every query change, repopulated only by a response.
///
/// **Per-library scope (deviation note):** the server tier is inherently per-library (the endpoint
/// requires a `libraryID`); the production `init(app:connectionID:libraryID:)` scopes the FTS tier
/// to the same library too, so both tiers agree. If a connection has multiple libraries, `SearchView`
/// searches the active/first one (documented there).
@Observable
@MainActor
final class SearchModel {
    typealias LocalSearch = @MainActor (String) async -> [ItemRow]
    typealias ServerSearch = @MainActor (String) async throws -> SearchResults

    /// Minimum query length before the server tier fires. The ABS `/search` endpoint 400s on an
    /// empty/missing `q`, and match quality below two characters is poor — so anything shorter
    /// stays local-only.
    static let minimumServerQueryLength = 2

    // MARK: Published result state (read by SearchView)

    /// The blended title rows (FTS placeholders enriched in place by the server `book` bucket).
    private(set) var titles: [ItemRow] = []
    /// Server-only entity buckets — always empty until a response lands, cleared on query change.
    private(set) var series: [SeriesSummary] = []
    private(set) var authors: [AuthorSummary] = []
    private(set) var narrators: [SearchNamedCount] = []
    private(set) var genres: [SearchNamedCount] = []
    private(set) var tags: [SearchNamedCount] = []
    /// `true` while the debounced server tier for the current query is in flight — drives the
    /// loading indicator. Owned by the newest query only: a superseded/cancelled task never writes it.
    private(set) var isSearching = false
    /// The current raw query, mirrored from `.searchable`.
    private(set) var query = ""

    // MARK: Injected dependencies (non-observed)

    @ObservationIgnored private let localSearch: LocalSearch
    @ObservationIgnored private let serverSearch: ServerSearch
    @ObservationIgnored private let debounceInterval: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Test hook: `await` this to run the current query's full local+server cycle to completion.
    var pendingSearch: Task<Void, Never>? { searchTask }

    init(localSearch: @escaping LocalSearch,
         serverSearch: @escaping ServerSearch,
         debounce: Duration = .milliseconds(275)) {
        self.localSearch = localSearch
        self.serverSearch = serverSearch
        self.debounceInterval = debounce
    }

    /// Production wiring: FTS tier backed by `LibraryCacheStore.searchItems` (scoped to `libraryID`),
    /// server tier by `ABSClient.searchLibrary`. `app` is read live inside the closures so a
    /// reconnect (fresh `client`) is picked up without rebuilding the model.
    convenience init(app: AppState, connectionID: String, libraryID: String,
                     debounce: Duration = .milliseconds(275)) {
        self.init(
            localSearch: { query in
                let rows = (try? app.cache.searchItems(connectionID: connectionID, query: query)) ?? []
                // FTS is connection-scoped; keep only the active library's rows so the local tier
                // matches the server tier's per-library scope.
                return rows.filter { $0.libraryID == libraryID }.map(ItemRow.init(cachedItem:))
            },
            serverSearch: { query in
                guard let client = app.client else { throw ABSError.notAuthenticated }
                return try await client.searchLibrary(libraryID: libraryID, query: query)
            },
            debounce: debounce)
    }

    /// The non-empty sections in canonical display order — the single source of truth for both
    /// `SearchView`'s section layout and the ordering test.
    var populatedSections: [SearchSection] {
        var result: [SearchSection] = []
        if !titles.isEmpty { result.append(.titles) }
        if !series.isEmpty { result.append(.series) }
        if !authors.isEmpty { result.append(.authors) }
        if !narrators.isEmpty { result.append(.narrators) }
        if !genres.isEmpty { result.append(.genres) }
        if !tags.isEmpty { result.append(.tags) }
        return result
    }

    /// Whether any section has content — used by `SearchView` to choose between the results list
    /// and the no-results empty state.
    var hasAnyResults: Bool { !populatedSections.isEmpty }

    /// Drives a query change: cancels any in-flight search, paints the instant local tier, then
    /// (debounced, ≥ 2 chars, cancel-in-flight) runs and merges the server tier.
    func updateQuery(_ raw: String) {
        // Cancel the previous query's task and hand the spinner to the new query — a cancelled
        // task never touches `isSearching`, so this is the only place it's reset on a query change.
        searchTask?.cancel()
        isSearching = false
        query = raw

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            searchTask = nil
            return
        }

        // Entity buckets belong to the PREVIOUS query's response (server-only) — clear them now so
        // a stale Authors/Series section never lingers under a new query while the server runs.
        series = []; authors = []; narrators = []; genres = []; tags = []

        let debounce = debounceInterval
        searchTask = Task { [weak self] in
            guard let self else { return }

            // Instant local tier — paints without waiting on the server.
            let localRows = await self.localSearch(trimmed)
            if Task.isCancelled { return }
            self.titles = localRows

            // Server tier is guarded to ≥ 2 chars: the empty/1-char 400 is impossible.
            guard trimmed.count >= Self.minimumServerQueryLength else { return }

            // Spinner covers the debounce + round trip so the no-results state can't flash between.
            self.isSearching = true

            // Debounced; a superseding query cancels this sleep.
            do { try await Task.sleep(for: debounce) } catch { return }
            if Task.isCancelled { return }

            // Server failure is non-fatal: `try?` keeps the local titles up. A late result from a
            // superseded query is dropped by the cancellation check before merging.
            let results = try? await self.serverSearch(trimmed)
            if Task.isCancelled { return }
            if let results { self.mergeServer(results) }
            self.isSearching = false
        }
    }

    // MARK: - Merge

    /// Merges a server response into the local titles by `libraryItem.id` (server row wins,
    /// enriched; new ids appended after the FTS rows) and replaces the server-only entity buckets.
    private func mergeServer(_ results: SearchResults) {
        var order = titles.map(\.id)
        var byID = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for hit in results.book ?? [] {
            var row = ItemRow(hit: hit)
            if let existing = byID[row.id] {
                // Carry the FTS row's cover cache-buster onto the (ts-less) server row.
                if row.updatedAt == nil { row.updatedAt = existing.updatedAt }
            } else {
                order.append(row.id)
            }
            byID[row.id] = row
        }
        titles = order.compactMap { byID[$0] }

        series = (results.series ?? []).map(\.series)
        authors = results.authors ?? []
        narrators = results.narrators ?? []
        genres = results.genres ?? []
        tags = results.tags ?? []
    }

    private func clearResults() {
        titles = []; series = []; authors = []; narrators = []; genres = []; tags = []
        isSearching = false
    }
}
