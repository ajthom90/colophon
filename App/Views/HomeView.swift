import SwiftUI
import ABSKit
import LibraryCache

/// The Home surface: a vertical scroll of personalized shelves (`GET /api/libraries/:id/
/// personalized`) for the active library, rendered as horizontally-scrolling `ShelfRow`s à la
/// Apple Music / Books. Liquid Glass discipline: the ONLY glass here is the system nav bar the
/// shell provides — shelves, headers, cards, artwork and text are all OPAQUE content.
/// `.scrollEdgeEffectStyle(.soft, for: .top)` makes cards fade softly under that nav glass.
///
/// Progress pills are fed by joining `me()`'s `mediaProgress` into `CachedProgress`
/// (`app.refreshProgress()`), then OBSERVING `CachedProgress` live so a socket `progressUpdated`
/// event updates a pill without refetching the shelf. Shelves themselves refresh on appear and on
/// pull-to-refresh.
struct HomeView: View {
    @Environment(AppState.self) private var app

    @State private var libraries: [CachedLibrary] = []
    @State private var shelves: [Shelf] = []
    /// Live `CachedProgress` keyed by `itemID` (book rows preferred over episode rows on collision).
    @State private var progressByItem: [String: CachedProgress] = [:]
    @State private var state: LoadState = .idle

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    /// Home shows shelves for the active (first) library — the plan's singular "active library".
    private var activeLibrary: CachedLibrary? { libraries.first }

    var body: some View {
        content
            .navigationTitle("Home")
            .task(id: app.activeConnectionID) { await observeLibraries() }
            .task(id: app.activeConnectionID) { await observeProgress() }
            // Reload shelves whenever the active library appears/changes.
            .task(id: activeLibrary?.id) { await loadShelves() }
    }

    @ViewBuilder
    private var content: some View {
        if shelves.isEmpty {
            switch state {
            case .idle, .loading:
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load Home", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await loadShelves() } }
                }
            case .loaded:
                ContentUnavailableView {
                    Label("No shelves yet", systemImage: "square.stack")
                } description: {
                    Text("This library has no personalized shelves.")
                }
            }
        } else {
            shelvesScroll
        }
    }

    private var shelvesScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(shelves) { shelf in
                    ShelfRow(shelf: shelf) { itemID in progressByItem[itemID] }
                }
            }
            .padding(.vertical)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await loadShelves() }
    }

    // MARK: - Data

    /// Observes the connection's cached library list, so Home always tracks the active library
    /// (and resets cleanly on a connection switch — no stale shelves flash).
    private func observeLibraries() async {
        libraries = []
        shelves = []
        state = .idle
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await value in app.cache.observeLibraries(connectionID: connectionID) {
                libraries = value
            }
        } catch {
            // The shelf load surfaces any real failure; a library-observation hiccup just leaves
            // Home on its spinner until the next connection change.
        }
    }

    /// Observes ALL of the connection's `CachedProgress` and indexes it by `itemID` so book cards'
    /// progress pills update live as socket events land. On an `itemID` collision (a podcast with
    /// several episodes), the book row (`episodeID == ""`) wins, else the newest `lastUpdate`.
    private func observeProgress() async {
        progressByItem = [:]
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeProgress(connectionID: connectionID) {
                progressByItem = rows.indexedByItem()
            }
        } catch {
            // Best-effort live updates; pills still paint from whatever the join already wrote.
        }
    }

    /// Fetches the active library's personalized shelves and joins `me()` progress so the pills
    /// have data as soon as the shelves paint. Keeps the last-good shelves on a transient failure
    /// (only surfaces the error state when there's nothing to show).
    private func loadShelves() async {
        guard let library = activeLibrary else { return }
        guard let client = app.client else {
            if shelves.isEmpty {
                state = .failed("You're offline — Home shelves need a live connection.")
            }
            return
        }
        if shelves.isEmpty { state = .loading }
        do {
            shelves = try await client.personalizedShelves(libraryID: library.id)
            state = .loaded
        } catch {
            if shelves.isEmpty {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        // The progress-join that feeds the pills — runs on appear and on every pull-to-refresh.
        await app.refreshProgress()
    }
}
