import SwiftUI
import ABSKit
import LibraryCache

/// iPhone shell: a `TabView` (system Liquid Glass tab bar, free) with Home / Library / Search /
/// Downloads tabs, a now-playing `MiniPlayerBar` in the bottom accessory (sits above the tab bar,
/// shares its glass), and `.onScrollDown` tab-bar minimization. For Task 6 the tab contents are
/// placeholders except Library, which wires the existing library browser so a book can be played
/// and the mini-bar exercised.
///
/// The Library tab's browse state (`libraries`/`selectedLibraryID`/`browseMode`) lives HERE, on
/// `PhoneShell`, and is threaded into `LibraryTabContent` as bindings — not owned as `@State`
/// directly on `LibraryTabContent`. This is a deliberate, empirically-forced workaround (M1c-a
/// Task 9): `LibraryTabContent` sits inside the Library tab's `NavigationStack` and swaps its root
/// content by a local `browseMode` switch (Grid/Series/Authors). Popping a pushed `AuthorDetailView`/
/// `SeriesDetailView` back to that root was observed (via `os.Logger` instrumentation reproduced
/// live on-device) to tear down and remount `LibraryTabContent` from scratch — its `.task(id:)`
/// restarts even though `AppState.activeConnectionID` never changed, silently resetting
/// `browseMode` to `.grid` and dropping the user right back on the Grid instead of the Series/
/// Authors mode they were browsing. `PhoneShell.body`, confirmed via the same instrumentation,
/// evaluates exactly ONCE across this whole navigation — so state owned here (`@State`, not a
/// child's) survives the child's remount untouched, and `LibraryTabContent`'s `.task` guards its
/// one-time reset on an explicit `initializedConnectionID` marker (also hoisted here) rather than
/// unconditionally resetting on every task invocation.
struct PhoneShell: View {
    @Environment(AppState.self) private var app
    @State private var showingFullPlayer = false
    @State private var libraries: [CachedLibrary] = []
    @State private var selectedLibraryID: String?
    @State private var browseMode: LibraryBrowseMode = .grid
    /// The connection ID `libraries`/`selectedLibraryID`/`browseMode` were last reset for — lets
    /// `LibraryTabContent`'s `.task(id:)` tell "a genuinely new connection" (reset) apart from "this
    /// task instance merely restarted after a remount, same connection as before" (don't reset).
    @State private var initializedConnectionID: String?
    /// Which tab is selected — a binding so a deep link (M2b Task 5) can drive it (select Home for an
    /// item/resume, Search for the Search phrase).
    @State private var selectedTab: ShellTab = .home
    /// The Home tab's navigation path — bound so a deep link can PUSH an item/podcast/episode detail
    /// programmatically (a normal `NavigationLink(value:)` still appends to it too). Home registers
    /// all three detail destinations at its stable root, so it's the single stack deep links drive.
    @State private var homePath = NavigationPath()

    private enum ShellTab: Hashable { case home, library, search, downloads }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: ShellTab.home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                        .offlineIndicator()
                        .accountMenu()
                }
            }
            Tab("Library", systemImage: "books.vertical", value: ShellTab.library) {
                NavigationStack {
                    LibraryTabContent(
                        libraries: $libraries,
                        selectedLibraryID: $selectedLibraryID,
                        browseMode: $browseMode,
                        initializedConnectionID: $initializedConnectionID)
                        .offlineIndicator()
                        .accountMenu()
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: ShellTab.search, role: .search) {
                NavigationStack {
                    SearchView()
                        .offlineIndicator()
                        .accountMenu()
                }
            }
            // Downloads (Task 7): the 4th/last tab per spec §7 (Home / Library / Search / Downloads)
            // — downloaded books/episodes, state, storage, delete/manage. Declared LAST so it renders
            // after Search. No offline indicator here: this surface IS the offline-first one (fully
            // local, nothing here depends on the network), so the banner would be redundant noise.
            Tab("Downloads", systemImage: "arrow.down.circle", value: ShellTab.downloads) {
                NavigationStack { DownloadsView().accountMenu() }
            }
        }
        .phoneTabChrome { MiniPlayerBar { showingFullPlayer = true } }
        // iPhone per-platform presentation (Task 4): an edge-to-edge `fullScreenCover` (native
        // slide-up). The presentation seam lives in `PlayerPresentation.swift` — see its morph note
        // for why this is a standard cover rather than a zoom morph.
        .iPhonePlayerCover(isPresented: $showingFullPlayer)
        // Drive navigation from a deep link / Siri phrase (M2b Task 5). `.onChange` catches links that
        // arrive while mounted; the `.task` catches one that set `pendingNavigation` before the shell
        // appeared (a cold-launch deep link routed after connect).
        .onChange(of: app.pendingNavigation) { _, _ in consumePending() }
        .task { consumePending() }
    }

    /// Route the pending deep-link destination into this shell's tab selection + Home stack, then
    /// clear it. Reads the LIVE `app.pendingNavigation` (not the `onChange` payload) so a mount-time
    /// race between `.task` and `.onChange` consumes it exactly once. `resume` is handled by
    /// `AppState` (playback), so there's nothing to navigate for it.
    private func consumePending() {
        guard let nav = app.pendingNavigation else { return }
        switch nav {
        case .item(let route): selectedTab = .home; homePath.append(route)
        case .podcast(let route): selectedTab = .home; homePath.append(route)
        case .episode(let route): selectedTab = .home; homePath.append(route)
        case .search: selectedTab = .search
        case .home: selectedTab = .home
        case .resume: break
        }
        app.consumePendingNavigation()
    }
}

/// The iPhone Library tab's three peer browse modes, reached via a toolbar **"Browse by" `Menu`**
/// (Grid / Series / Authors), not a segmented control: `LibraryGridView`'s Grid mode already
/// contributes its own Sort + Filter toolbar buttons, and a 3-way segmented control competing for
/// the same compact nav bar would either crowd those or force a second toolbar row/section. A
/// `Menu` is the same idiom already established by Sort/Filter, scales without layout pressure, and
/// costs one extra tap to see the current mode — the right trade for three peer, infrequently-
/// switched modes. Declared at file scope (not nested in `LibraryTabContent`) so `PhoneShell` can
/// hold the `@State` for it (see `PhoneShell`'s doc comment for why).
private enum LibraryBrowseMode: String, CaseIterable, Identifiable {
    case grid = "Grid", series = "Series", authors = "Authors"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .series: return "square.stack"
        case .authors: return "person.2"
        }
    }
}

/// The iPhone Library tab's content: shows the active (first) library's `LibraryGridView`, with a
/// toolbar library picker when the connection has more than one library (the plan's "keep it
/// simple: Library shows the active/first library's grid, with a library picker if >1"), plus
/// M1c-a Task 9's Series/Authors browse modes. Observes the connection's cached library list so it
/// tracks connection switches and resets cleanly. All the actual browse STATE is owned by the
/// parent `PhoneShell` and threaded in as bindings — see `PhoneShell`'s doc comment.
private struct LibraryTabContent: View {
    @Environment(AppState.self) private var app
    @Binding var libraries: [CachedLibrary]
    @Binding var selectedLibraryID: String?
    @Binding var browseMode: LibraryBrowseMode
    @Binding var initializedConnectionID: String?

    private var selected: CachedLibrary? {
        libraries.first { $0.id == selectedLibraryID } ?? libraries.first
    }

    var body: some View {
        Group {
            if let library = selected {
                content(for: library)
            } else {
                ContentUnavailableView {
                    Label("No Libraries", systemImage: "books.vertical")
                } description: {
                    Text("This connection has no libraries yet.")
                }
                .navigationTitle("Library")
            }
        }
        // Registered here, on this outer `Group` — NOT inside `SeriesListView`/`AuthorsListView`
        // themselves (see those views' doc comments): those are reached through the `browseMode`
        // switch below, i.e. conditionally mounted as this Group's descendant, and a destination
        // self-registered on a conditionally-mounted view is the fragile pattern `ConnectionsView`
        // already warns about. `selected` inside the closures is safe: a value can only be pushed
        // from `SeriesListView`/`AuthorsListView`, which only render for the CURRENT `selected`.
        .navigationDestination(for: SeriesSummary.self) { series in
            if let library = selected { SeriesDetailView(library: library, series: series) }
        }
        .navigationDestination(for: AuthorSummary.self) { author in
            if let library = selected { AuthorDetailView(library: library, author: author) }
        }
        // Same stable-root rationale as the Series/Authors destinations above: registered here on
        // the Library stack's root so a `CoverCard` tap in the Grid, an author's book grid, or a
        // series' book grid all resolve `ItemDetailRoute` (they're reached through the mode switch,
        // so they must not self-register).
        .itemDetailDestination()
        // A podcast library's Grid pushes `PodcastDetailRoute` → `PodcastDetailView`; registered on
        // the same stable root as the book route above.
        .podcastDetailDestination()
        // An episode row (inside `PodcastDetailView`, reached through the destination above) pushes
        // `EpisodeDetailRoute`; registered on the same stable root, inside the stack.
        .episodeDetailDestination()
        .task(id: app.activeConnectionID) {
            let connectionID = app.activeConnectionID
            // Only reset the browse state for a GENUINELY new connection — not on every
            // invocation. Without this guard, the remount described in `PhoneShell`'s doc comment
            // would silently reset `browseMode`/`selectedLibraryID` on every pop back to this
            // screen's root, even though the connection never changed.
            if connectionID != initializedConnectionID {
                libraries = []
                selectedLibraryID = nil
                browseMode = .grid
                initializedConnectionID = connectionID
            }
            guard let connectionID else { return }
            do {
                for try await value in app.cache.observeLibraries(connectionID: connectionID) {
                    libraries = value
                }
            } catch {
                app.errorMessage = "Library list unavailable: \(error.localizedDescription)"
            }
        }
        // A library switch (via the Grid mode's own picker) resets to Grid — a stale Series/
        // Authors selection from a DIFFERENT library should never silently carry over.
        .onChange(of: selected?.id) { _, _ in browseMode = .grid }
    }

    @ViewBuilder
    private func content(for library: CachedLibrary) -> some View {
        if library.mediaType == "podcast" {
            // Podcasts have no Series/Authors (book concepts) — only the podcast grid, and NO
            // "Browse by" menu (nothing to switch to). The grid keeps its own library picker.
            // Guarding here (not just on the mode switch) means a stale `browseMode` carried from a
            // book library can never render Series/Authors for a podcast library.
            LibraryGridView(library: library, siblings: libraries, onSelectLibrary: { selectedLibraryID = $0.id })
        } else {
            switch browseMode {
            case .grid:
                LibraryGridView(library: library, siblings: libraries, onSelectLibrary: { selectedLibraryID = $0.id })
                    .toolbar { browseByMenu }
            case .series:
                SeriesListView(library: library)
                    .toolbar { browseByMenu }
            case .authors:
                AuthorsListView(library: library)
                    .toolbar { browseByMenu }
            }
        }
    }

    @ToolbarContentBuilder
    private var browseByMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Browse by", selection: $browseMode) {
                    ForEach(LibraryBrowseMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
            } label: {
                Label("Browse by", systemImage: browseMode.icon)
            }
        }
    }
}

private extension View {
    /// The iOS-only tab chrome: a now-playing bottom accessory and `.onScrollDown` tab-bar
    /// minimization. `tabViewBottomAccessory` is iOS/iPadOS/Mac-Catalyst-only (NOT native macOS —
    /// verified), so both modifiers are gated; on macOS this is a no-op (`PhoneShell` is never
    /// shown there — `RootShell` routes the Mac to `SplitShell`, but the file still compiles for
    /// the macOS target).
    @ViewBuilder
    func phoneTabChrome<Accessory: View>(@ViewBuilder accessory: @escaping () -> Accessory) -> some View {
        #if os(iOS)
        self
            .tabViewBottomAccessory(content: accessory)
            .tabBarMinimizeBehavior(.onScrollDown)
        #else
        self
        #endif
    }
}
