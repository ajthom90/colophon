import SwiftUI
import ABSKit
import LibraryCache

/// iPad & Mac shell: a `NavigationSplitView` with a system-glass sidebar (Home, each library,
/// Search — the sidebar gets platform glass for free and is never re-skinned) and a swapping
/// detail column. The now-playing transport is a hand-built full-width bar docked via
/// `.safeAreaInset(edge: .bottom)` (NOT a floating player). This shell uses the docked bar on BOTH
/// iPad and Mac: `tabViewBottomAccessory` needs a `TabView`, and this shell is split-view-based,
/// so the single docked bar is the cleaner choice across both. The Mac additionally exposes a
/// Playback command menu (see `PlaybackCommands`, attached in `ColophonApp`).
struct SplitShell: View {
    @Environment(AppState.self) private var app
    #if os(macOS)
    // Mac full-player presentation is a dedicated Window (NOT a sheet takeover) — opened here,
    // declared as a `Window(id:)` scene in `ColophonApp`. See `PlayerWindowScene`.
    @Environment(\.openWindow) private var openWindow
    #endif
    // Optional so `List(selection:)` binds the single-selection sidebar initializer; `nil` falls
    // back to Home in the detail column.
    @State private var selection: SidebarItem? = .home
    /// iPad full-player presentation flag (a large detented sheet on the detail column). Unused on
    /// macOS, where the transport's expand affordance opens the dedicated player Window instead.
    @State private var showingFullPlayer = false
    @State private var libraries: [CachedLibrary] = []
    /// Library IDs whose sidebar row is collapsed (Series/Authors hidden). Empty by default —
    /// every library's browse rows start expanded, since the dev fixture has exactly one library
    /// and hiding its only children by default would bury Task 9's entry points.
    @State private var collapsedLibraryIDs: Set<String> = []
    /// The Home detail column's navigation path — bound so a deep link (M2b Task 5) can PUSH an
    /// item/podcast/episode detail into it. Home registers all three detail destinations at its root,
    /// so deep links select the `.home` sidebar row and push onto this one stack.
    @State private var homePath = NavigationPath()

    enum SidebarItem: Hashable {
        case home
        case search
        case downloads
        case library(CachedLibrary)
        case series(CachedLibrary)
        case authors(CachedLibrary)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Home", systemImage: "house").tag(SidebarItem.home)
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                    // Downloads (Task 7): the Mac/iPad sidebar entry point — downloaded books/
                    // episodes, state, storage, delete/manage, same `DownloadsView` the iPhone tab uses.
                    Label("Downloads", systemImage: "arrow.down.circle").tag(SidebarItem.downloads)
                }
                // Series/Authors nest UNDER each library (an outline/disclosure row, à la Music's
                // Library sidebar nesting Playlists/Artists/Albums) rather than as flat top-level
                // rows — this is what "under the active library" means for a sidebar that lists
                // every library, not just a single active one. `DisclosureGroup` inside a
                // `List(selection:)` is the standard SwiftUI hierarchical-sidebar idiom (Mail/Notes):
                // the nested `Label`s keep participating in the same single-selection binding via
                // their own `.tag`.
                Section("Libraries") {
                    ForEach(libraries) { library in
                        if library.mediaType == "podcast" {
                            // Podcasts have no Series/Authors (book concepts) — a plain row that
                            // browses the podcast grid, no disclosure children.
                            Label(library.name, systemImage: "antenna.radiowaves.left.and.right")
                                .tag(SidebarItem.library(library))
                        } else {
                            DisclosureGroup(isExpanded: expansionBinding(for: library)) {
                                Label("Series", systemImage: "square.stack").tag(SidebarItem.series(library))
                                Label("Authors", systemImage: "person.2").tag(SidebarItem.authors(library))
                            } label: {
                                Label(library.name, systemImage: "books.vertical")
                                    .tag(SidebarItem.library(library))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Colophon")
            .accountMenu()
        } detail: {
            detailColumn
        }
        // Dock the transport on the WHOLE `NavigationSplitView` (not just the detail column) so it
        // spans the FULL window width — sidebar + detail — the standard Music-style bottom transport.
        // Attached here rather than inside `detail:` because a `safeAreaInset` on the detail column
        // alone left the bar spanning only that column's width, so on Mac it read as invisible.
        .safeAreaInset(edge: .bottom) {
            TransportBar {
                #if os(macOS)
                openWindow(id: PlayerWindowScene.id)
                #else
                showingFullPlayer = true
                #endif
            }
        }
        // iPad per-platform presentation (Task 4): a large detented sheet. No-op on macOS (the Mac
        // uses the dedicated player Window above).
        .iPadPlayerSheet(isPresented: $showingFullPlayer)
        // Drive navigation from a deep link / Siri phrase (M2b Task 5) — select the target sidebar
        // row + push onto the Home detail stack. `.task` catches a cold-launch link that set
        // `pendingNavigation` before this shell appeared.
        .onChange(of: app.pendingNavigation) { _, _ in consumePending() }
        .task { consumePending() }
        .task(id: app.activeConnectionID) {
            // Reset before observing so a connection switch never flashes the previous
            // connection's libraries, and never leaves a stale library selected.
            libraries = []
            selection = .home
            guard let connectionID = app.activeConnectionID else { return }
            do {
                for try await value in app.cache.observeLibraries(connectionID: connectionID) {
                    libraries = value
                }
            } catch {
                app.errorMessage = "Library list unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func expansionBinding(for library: CachedLibrary) -> Binding<Bool> {
        Binding(
            get: { !collapsedLibraryIDs.contains(library.id) },
            set: { expanded in
                if expanded { collapsedLibraryIDs.remove(library.id) } else { collapsedLibraryIDs.insert(library.id) }
            })
    }

    @ViewBuilder
    private var detailColumn: some View {
        // Each case owns its own `NavigationStack` so the detail column shows a title bar and
        // resets cleanly on selection change. A `CoverCard` tap pushes `ItemDetailView` via
        // `ItemDetailRoute`, so every stack that hosts cards registers `.itemDetailDestination()`
        // at its literal, unconditional root (Search/Home self-register it). The sidebar already
        // lists every library, so the grid is given no in-tab picker (`siblings` defaults empty).
        //
        // `.series`/`.authors` register their push destinations HERE, at the `NavigationStack`'s
        // literal, unconditional root — not inside `SeriesListView`/`AuthorsListView` themselves
        // (see those views' doc comments: a destination self-registered on a view that some OTHER
        // caller mounts conditionally, as `PhoneShell` does, resets that caller's state on pop).
        // This stack's root never changes shape once a sidebar row is selected, so it's a stable
        // registration point.
        // The destinations are registered on each stack's ROOT CONTENT VIEW, INSIDE the
        // `NavigationStack` — NOT on the `NavigationStack` value itself. In a `NavigationSplitView`
        // a `navigationDestination` attached to the outside of a column's stack is treated as a
        // COLUMN destination and targets the next column; the detail column has no next column, so
        // a `CoverCard` tap dead-ends ("There is no next column after the detail column"). Placing
        // it on the stack's root content pushes within the detail column, matching how `HomeView`/
        // `SearchView` self-register (they're the unconditional root of their own stacks). The
        // root content is still the stable registration point — it never changes shape once a
        // sidebar row is selected — so the "don't self-register on a conditionally-mounted view"
        // rule the browse views' doc comments describe is honored.
        switch selection {
        case .search:
            NavigationStack { SearchView().offlineIndicator() }
        case .downloads:
            // `DownloadsView` registers its OWN `.itemDetailDestination()`/`.episodeDetailDestination()`
            // at its root content, inside this stack — the same macOS nav-gotcha rule every other
            // case here follows. No offline indicator (see the sidebar Label's comment): Downloads
            // is the fully-local surface, nothing here depends on the network.
            NavigationStack { DownloadsView() }
        case .library(let library):
            NavigationStack {
                LibraryGridView(library: library)
                    .itemDetailDestination()
                    // A podcast library's grid pushes `PodcastDetailRoute`; register it here on the
                    // stack's ROOT CONTENT (inside the stack, same rule as `.itemDetailDestination()`)
                    // so a podcast card resolves to `PodcastDetailView` within the detail column.
                    .podcastDetailDestination()
                    // An episode row (inside `PodcastDetailView`, reached through the destination
                    // above) pushes `EpisodeDetailRoute`; registered on this SAME root content, inside
                    // the stack, so it resolves within the detail column rather than dead-ending.
                    .episodeDetailDestination()
                    .offlineIndicator()
            }
        case .series(let library):
            NavigationStack {
                SeriesListView(library: library)
                    .navigationDestination(for: SeriesSummary.self) { SeriesDetailView(library: library, series: $0) }
                    .itemDetailDestination()
                    // Parity with .search/.library/.home (and the iPhone shell): the series surface
                    // is network-backed, so it shows the offline banner when the server is unreachable.
                    .offlineIndicator()
            }
        case .authors(let library):
            NavigationStack {
                AuthorsListView(library: library)
                    .navigationDestination(for: AuthorSummary.self) { AuthorDetailView(library: library, author: $0) }
                    .itemDetailDestination()
                    // Parity with .search/.library/.home (and the iPhone shell): authors are
                    // network-backed, so surface the offline banner when the server is unreachable.
                    .offlineIndicator()
            }
        case .home, .none:
            NavigationStack(path: $homePath) { HomeView().offlineIndicator() }
        }
    }

    /// Route the pending deep-link destination into this shell's sidebar selection + Home stack, then
    /// clear it. Reads the LIVE `app.pendingNavigation` (not the `onChange` payload) so a mount-time
    /// race between `.task` and `.onChange` consumes it exactly once. `resume` is handled by
    /// `AppState` (playback), so there's nothing to navigate for it.
    private func consumePending() {
        guard let nav = app.pendingNavigation else { return }
        switch nav {
        case .item(let route): selection = .home; homePath.append(route)
        case .podcast(let route): selection = .home; homePath.append(route)
        case .episode(let route): selection = .home; homePath.append(route)
        case .search: selection = .search
        case .home: selection = .home
        case .resume: break
        }
        app.consumePendingNavigation()
    }
}

#if os(macOS)
/// Mac-only Playback command menu — the full Mac keyboard/menu transport for the shared
/// `PlaybackController`, every item disabled when no session is active (`totalDuration <= 0`) and
/// chapter navigation additionally disabled when the book has no chapters. All shortcuts are
/// NON-Space (the M1c-a fix stands — see the play/pause note below):
///   • Play/Pause — menu action, **no** keyboard shortcut.
///   • Skip Back / Forward — `⌘←` / `⌘→` (modifier-gated so plain arrow-key sidebar navigation is
///     untouched), by the Settings-configured `skipInterval`.
///   • Previous / Next Chapter — `⌥⌘←` / `⌥⌘→`, wired via `PlayerModel` over `nowPlayingChapters`.
///   • Decrease / Increase Speed — `⇧⌘,` / `⇧⌘.` (⌘, alone is macOS's Settings shortcut, so the
///     speed steppers are Shift-modified), stepping through `rates`; plus the direct-select submenu.
struct PlaybackCommands: Commands {
    var app: AppState
    private let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// True while a book is loaded — every command is gated on this.
    private var hasSession: Bool { app.playback.totalDuration > 0 }
    /// True while a book with chapters is loaded — gates chapter next/prev.
    private var hasChapters: Bool { hasSession && !app.nowPlayingChapters.isEmpty }

    var body: some Commands {
        CommandMenu("Playback") {
            // Show Player (⌘0): open the dedicated player Window (the same `PlayerWindowScene` the
            // transport's expand affordance opens). Lives in a child View because `openWindow` is an
            // `@Environment` value only a View can read, not a `Commands` struct. Session-guarded
            // like the rest — no point opening an empty player with nothing loaded.
            ShowPlayerButton(disabled: !hasSession)

            Divider()

            // No `.keyboardShortcut(.space, ...)` here on purpose: AppKit resolves menu
            // key-equivalents in sendEvent before a focused field editor sees the key, so a
            // bare-Space shortcut would hijack Space typed into the sidebar's `.searchable`
            // Search field (SearchView) and would also collide with Space-as-page-down in any
            // ScrollView. Menu-click and media keys are the supported Mac play/pause controls.
            Button(app.playback.isPlaying ? "Pause" : "Play") {
                app.playback.togglePlayPause()
            }
            .disabled(!hasSession)

            Divider()

            Button("Skip Forward") {
                app.playback.skip(Double(app.playback.skipInterval))
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!hasSession)

            Button("Skip Back") {
                app.playback.skip(-Double(app.playback.skipInterval))
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!hasSession)

            Divider()

            Button("Next Chapter") {
                PlayerModel(app: app).goToNextChapter()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(!hasChapters)

            Button("Previous Chapter") {
                PlayerModel(app: app).goToPreviousChapter()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(!hasChapters)

            Divider()

            Button("Increase Speed") { adjustRate(by: 1) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!hasSession)

            Button("Decrease Speed") { adjustRate(by: -1) }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                .disabled(!hasSession)

            Menu("Playback Speed") {
                ForEach(rates, id: \.self) { rate in
                    Button(String(format: "%g×", rate)) { app.playback.setRate(Float(rate)) }
                }
            }
            .disabled(!hasSession)
        }
    }

    /// Steps `rate` by `delta` positions through `rates`, clamped to the ends. Snaps to the nearest
    /// listed rate first (the current rate may be an off-list value from a per-book default), then
    /// moves — so `⇧⌘.`/`⇧⌘,` always land on a defined preset.
    private func adjustRate(by delta: Int) {
        let current = Double(app.playback.rate)
        let nearest = rates.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset
            ?? rates.firstIndex(of: 1.0) ?? 0
        let target = min(max(nearest + delta, 0), rates.count - 1)
        app.playback.setRate(Float(rates[target]))
    }
}

/// The "Show Player" menu item's action needs `@Environment(\.openWindow)`, which only a `View` can
/// read — not the `PlaybackCommands` `Commands` struct — so it lives here and is embedded in the
/// Playback menu. Opens the dedicated Mac player Window (`PlayerWindowScene`).
private struct ShowPlayerButton: View {
    @Environment(\.openWindow) private var openWindow
    let disabled: Bool

    var body: some View {
        Button("Show Player") { openWindow(id: PlayerWindowScene.id) }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(disabled)
    }
}
#endif
