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
    /// Live `CachedProgress` keyed by `itemID` (book rows preferred over episode rows on collision) —
    /// feeds book/podcast `CoverCard` pills.
    @State private var progressByItem: [String: CachedProgress] = [:]
    /// Live `CachedProgress` keyed by the FULL `itemID + "/" + episodeID` (M1c-c Task 7) — feeds
    /// `EpisodeCard` pills. Unlike `progressByItem` (which collapses every row sharing an `itemID`
    /// down to one "best" row — wrong for a podcast, whose episodes all share the PODCAST's `itemID`),
    /// this keeps every episode's row distinct so an episode card resolves ITS OWN progress, never a
    /// sibling episode's.
    @State private var progressByItemEpisode: [String: CachedProgress] = [:]
    /// Book-level download state (M2a Task 8), keyed by `itemID` — feeds `CoverCard`'s badge on a
    /// book/podcast-item shelf card. Only a book-shaped `CachedDownload` row (`episodeID` empty)
    /// keys onto an item this way; episode rows feed `downloadStateByItemEpisode` instead.
    @State private var downloadStateByItem: [String: String] = [:]
    /// Episode-level download state, keyed by `itemID + "/" + episodeID` (mirrors
    /// `progressByItemEpisode`) — feeds `EpisodeCard`'s badge with THIS episode's own state, never a
    /// sibling's.
    @State private var downloadStateByItemEpisode: [String: String] = [:]
    @State private var state: LoadState = .idle

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    /// Home shows shelves for the active (first) library — the plan's singular "active library".
    private var activeLibrary: CachedLibrary? { libraries.first }

    var body: some View {
        content
            .navigationTitle("Home")
            // Registered on HomeView because it's the unconditional root of both shells' Home
            // NavigationStack (PhoneShell's Home tab, SplitShell's `.home` detail) — a stable
            // self-registration point, unlike the browse views reached through a mode switch.
            .itemDetailDestination()
            // M1c-c Task 7: a podcast library's Home shows `.book`-shaped "recently-added" cards
            // (routed to `PodcastDetailRoute`, see `ShelfRow`) and `.episode`-shaped cards (routed to
            // `EpisodeDetailRoute`, see `EpisodeCard`) — both destinations MUST be registered here,
            // on this SAME stable root, alongside `.itemDetailDestination()` above, or a card tapped
            // from Home dead-ends on Mac ("There is no next column after the detail column"). This
            // was the deferred Task-4 Home→podcast gap: the Library stacks already registered both
            // (Tasks 4/6), but Home never did until now.
            .podcastDetailDestination()
            .episodeDetailDestination()
            .task(id: app.activeConnectionID) { await observeLibraries() }
            .task(id: app.activeConnectionID) { await observeProgress() }
            .task(id: app.activeConnectionID) { await observeDownloads() }
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
                    ShelfRow(
                        shelf: shelf,
                        progressFor: { itemID in progressByItem[itemID] },
                        episodeProgressFor: { itemID, episodeID in
                            progressByItemEpisode[itemID + "/" + episodeID]
                        },
                        downloadStateFor: { itemID in downloadStateByItem[itemID] },
                        episodeDownloadStateFor: { itemID, episodeID in
                            downloadStateByItemEpisode[itemID + "/" + episodeID]
                        })
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

    /// Observes ALL of the connection's `CachedProgress` and indexes it TWO ways so both book/podcast
    /// AND episode shelf cards get live-updating pills as socket events land:
    /// - `progressByItem` (`indexedByItem()`) — keyed by `itemID` alone, collapsing every row sharing
    ///   an item down to one "best" row (book row wins, else newest `lastUpdate`). Right for a
    ///   `CoverCard` (one pill per book/podcast item).
    /// - `progressByItemEpisode` (`indexedByItemAndEpisode()`) — keyed by the FULL `itemID + "/" +
    ///   episodeID`, so a podcast's several episodes (which all share the PODCAST's `itemID` in the
    ///   3-part `cachedProgress` PK) each resolve THEIR OWN row via `EpisodeCard`, never a sibling
    ///   episode's or the item-collapsed "best" row.
    private func observeProgress() async {
        progressByItem = [:]
        progressByItemEpisode = [:]
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeProgress(connectionID: connectionID) {
                progressByItem = rows.indexedByItem()
                progressByItemEpisode = rows.indexedByItemAndEpisode()
            }
        } catch {
            // Best-effort live updates; pills still paint from whatever the join already wrote.
        }
    }

    /// Indexes the connection's downloads TWO ways for the shelf badges (M2a Task 8), mirroring
    /// `observeProgress`'s split: a book-shaped row (`episodeID` empty) keys `downloadStateByItem`
    /// directly by `itemID`; an episode-shaped row keys `downloadStateByItemEpisode` by the FULL
    /// `itemID + "/" + episodeID` so a podcast's several episodes each resolve THEIR OWN state.
    private func observeDownloads() async {
        downloadStateByItem = [:]
        downloadStateByItemEpisode = [:]
        guard let connectionID = app.activeConnectionID else { return }
        do {
            for try await rows in app.cache.observeDownloads(connectionID: connectionID) {
                downloadStateByItem = Dictionary(
                    rows.filter { $0.episodeID.isEmpty }.map { ($0.itemID, $0.state) },
                    uniquingKeysWith: { _, latest in latest })
                downloadStateByItemEpisode = Dictionary(
                    rows.filter { !$0.episodeID.isEmpty }
                        .map { ($0.itemID + "/" + $0.episodeID, $0.state) },
                    uniquingKeysWith: { _, latest in latest })
            }
        } catch {
            // Best-effort live badges; shelves still paint without them.
        }
    }

    /// Fetches the active library's personalized shelves and joins `me()` progress so the pills
    /// have data as soon as the shelves paint. Keeps the last-good shelves on a transient failure
    /// (only surfaces the error state when there's nothing to show).
    private func loadShelves() async {
        guard let library = activeLibrary else { return }
        // `app.isOffline` (M2a Task 7): the server is KNOWN-unreachable (probe failed — the common
        // self-hosted "server stopped, device online" case the raw link state can't see). A live
        // `personalizedShelves` call would only fail after the transport timeout, reading as a hung
        // spinner — degrade immediately instead. Keyed on `isOffline` (not the raw link, not bare
        // `!isOnline`), so a healthy launch and the initial in-flight probe both proceed normally.
        guard let client = app.client, !app.isOffline else {
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
        // Publish the continue-listening shelf into the App Group for the home widget (M2b Task 1).
        // AFTER the progress join so the snapshot's per-entry progress reads the freshly-joined cache.
        app.publishContinueListeningSnapshot(from: shelves)
    }
}
