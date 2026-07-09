import SwiftUI
import ABSKit
import LibraryCache

/// The native library-browse surface: a `LazyVGrid` of `CoverCard`s (à la Apple Books / Music),
/// with a system-toolbar sort control and a filter sheet. The M0 perf spike confirmed `LazyVGrid`
/// handles ~10k covers on the Mac, so it is reused here (no `NSCollectionView`).
///
/// Liquid Glass discipline (a review criterion): the ONLY glass is the system toolbar the shell/
/// navigation provides — the grid, cards, artwork, text and the filter-sheet content are all
/// OPAQUE. `.scrollEdgeEffectStyle(.soft, for: .top)` makes the cards fade softly under the toolbar
/// glass as they scroll up.
///
/// Data flow: the grid OBSERVES `LibraryCacheStore.observeItems` for instant paint (cached rows,
/// title order) and live cover/metadata updates, while a background `AppState.refreshItems`
/// (uncapped, Task 3) fetches the authoritative sort/filter order from the server into the cache.
/// The visible order is `AppState.libraryItemOrder` (the server-returned order captured by that
/// refresh); before the first refresh completes — or offline — it falls back to the cache's title
/// order, so the grid is never blank when there are cached rows. Progress pills are fed by a live
/// `observeProgress` join and use `CachedItem.duration` as the fraction's duration source (the
/// Task 7-review fix).
struct LibraryGridView: View {
    @Environment(AppState.self) private var app
    let library: CachedLibrary
    /// Sibling libraries for the in-tab library picker. `PhoneShell` passes all of the connection's
    /// libraries (a Menu appears when there is more than one); `SplitShell`, whose sidebar already
    /// lists every library, passes nothing so no redundant picker shows.
    var siblings: [CachedLibrary] = []
    /// Invoked when the user picks a different library from the in-tab picker (PhoneShell only).
    var onSelectLibrary: ((CachedLibrary) -> Void)? = nil

    /// All cached rows for this library, indexed by id — the row content the grid renders.
    @State private var itemsByID: [String: CachedItem] = [:]
    /// The cache's title-ordered id list — the fallback order until a server refresh captures one.
    @State private var observedOrder: [String] = []
    @State private var progressByItem: [String: CachedProgress] = [:]
    /// This library's book-level download state (M2a Task 8), keyed by `itemID` — feeds each
    /// `CoverCard`'s compact `DownloadStateBadge` so the grid shows what's offline-available at a
    /// glance. A podcast ITEM is never itself downloaded (only its episodes are), so a podcast card
    /// simply finds no entry here and shows no badge.
    @State private var downloadStateByItem: [String: String] = [:]
    @State private var didReceiveItems = false
    @State private var loadError: String?
    @State private var showingFilter = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    /// The items to render, in the server-authoritative order captured by the last `refreshItems`
    /// (which, when a filter is active, is exactly the matching set). The distinction between "no
    /// order captured yet" (key absent → instant/offline paint in the cache's title order) and
    /// "order captured, zero matches" (key present but empty → the "No matches" empty state) is
    /// explicit: a present-but-empty order must NOT fall back to the whole cached library, or a
    /// zero-match filter would render every item.
    private var orderedItems: [CachedItem] {
        if let serverOrder = app.libraryItemOrder[library.id] {
            return serverOrder.compactMap { itemsByID[$0] }   // captured (empty → No matches)
        }
        return observedOrder.compactMap { itemsByID[$0] }     // not captured → title-order paint
    }

    var body: some View {
        content
            .navigationTitle(library.name)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingFilter) { FilterSheet(library: library) }
            .overlay(alignment: .top) {
                // Only this library's refresh failure — never some other library's banner.
                if !orderedItems.isEmpty, let banner = app.refreshBanner, banner.libraryID == library.id {
                    RefreshBanner(message: banner.message, retry: { app.retryRefresh(libraryID: library.id) })
                }
            }
            .task(id: library.id) { await observeItems() }
            .task(id: library.id) { await observeProgress() }
            .task(id: library.id) { await observeDownloads() }
            .task(id: browseKey) { await refresh() }
            // A library switch clears the facet filter — another library's author/series IDs won't
            // match (fires on CHANGE only, so a fresh grid still starts from its default nil filter).
            .onChange(of: library.id) { _, _ in app.libraryFilter = nil }
    }

    @ViewBuilder
    private var content: some View {
        if orderedItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(orderedItems) { item in
                        CoverCard(
                            itemID: item.id,
                            updatedAt: item.updatedAt,
                            title: item.title,
                            author: item.authorName,
                            duration: item.duration,
                            progress: progressByItem[item.id],
                            isPodcast: library.mediaType == "podcast",
                            downloadState: downloadStateByItem[item.id])
                    }
                }
                .padding()
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if itemsByID.isEmpty, let loadError {
            ContentUnavailableView {
                Label("Couldn't load library", systemImage: "wifi.exclamationmark")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") { Task { await refresh() } }
            }
        } else if app.libraryFilter != nil {
            ContentUnavailableView {
                Label("No matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No books match the current filter.")
            } actions: {
                Button("Clear Filter") { app.libraryFilter = nil }
            }
        } else if !didReceiveItems {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No audiobooks", systemImage: "books.vertical")
            } description: {
                Text("This library has no items yet.")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if siblings.count > 1, let onSelectLibrary {
            ToolbarItem {
                Menu {
                    ForEach(siblings) { lib in
                        Button {
                            onSelectLibrary(lib)
                        } label: {
                            if lib.id == library.id {
                                Label(lib.name, systemImage: "checkmark")
                            } else {
                                Text(lib.name)
                            }
                        }
                    }
                } label: {
                    Label("Library", systemImage: "books.vertical")
                }
            }
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: sortBinding) {
                    ForEach(LibrarySort.allCases) { sort in Text(sort.label).tag(sort) }
                }
                Picker("Order", selection: descBinding) {
                    Label("Ascending", systemImage: "arrow.up").tag(false)
                    Label("Descending", systemImage: "arrow.down").tag(true)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem {
            Button {
                showingFilter = true
            } label: {
                Label("Filter", systemImage: app.libraryFilter == nil
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }

    private var sortBinding: Binding<LibrarySort> {
        Binding(get: { app.librarySort }, set: { app.librarySort = $0 })
    }

    private var descBinding: Binding<Bool> {
        Binding(get: { app.sortDescending }, set: { app.sortDescending = $0 })
    }

    // MARK: - Data

    /// A key that re-triggers `refresh()` whenever the library OR the sort/order/filter changes,
    /// so a toolbar selection fires a fresh server `items?sort=&desc=&filter=` request into the cache.
    private var browseKey: String {
        "\(library.id)|\(app.librarySort.rawValue)|\(app.sortDescending)|\(app.libraryFilter?.queryValue ?? "")"
    }

    private func observeItems() async {
        itemsByID = [:]
        observedOrder = []
        didReceiveItems = false
        do {
            for try await value in app.cache.observeItems(connectionID: library.connectionID, libraryID: library.id) {
                itemsByID = Dictionary(value.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                observedOrder = value.map(\.id)
                didReceiveItems = true
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func observeProgress() async {
        progressByItem = [:]
        do {
            for try await rows in app.cache.observeProgress(connectionID: library.connectionID) {
                progressByItem = rows.indexedByItem()
            }
        } catch {
            // Best-effort live pills; the grid still paints without progress.
        }
    }

    /// Book-level download state for this grid's badges (M2a Task 8) — every `CachedDownload` row is
    /// itself either a book (`episodeID` empty) or a podcast episode; only the book-shaped rows key
    /// onto an ITEM this grid renders directly, so episode rows are filtered out here (their badge
    /// lives on `EpisodeRow`/`EpisodeCard` instead, joined per-episode there).
    private func observeDownloads() async {
        downloadStateByItem = [:]
        do {
            for try await rows in app.cache.observeDownloads(connectionID: library.connectionID) {
                downloadStateByItem = Dictionary(
                    rows.filter { $0.episodeID.isEmpty }.map { ($0.itemID, $0.state) },
                    uniquingKeysWith: { _, latest in latest })
            }
        } catch {
            // Best-effort live badges; the grid still paints without them.
        }
    }

    private func refresh() async {
        loadError = nil
        do {
            try await app.refreshItems(libraryID: library.id)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
