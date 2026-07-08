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

    enum SidebarItem: Hashable {
        case home
        case search
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
                        DisclosureGroup(isExpanded: expansionBinding(for: library)) {
                            Label("Series", systemImage: "square.stack").tag(SidebarItem.series(library))
                            Label("Authors", systemImage: "person.2").tag(SidebarItem.authors(library))
                        } label: {
                            Label(library.name,
                                  systemImage: library.mediaType == "podcast"
                                    ? "antenna.radiowaves.left.and.right" : "books.vertical")
                                .tag(SidebarItem.library(library))
                        }
                    }
                }
            }
            .navigationTitle("Colophon")
            .accountMenu()
        } detail: {
            detailColumn
                .safeAreaInset(edge: .bottom) {
                    TransportBar {
                        #if os(macOS)
                        openWindow(id: PlayerWindowScene.id)
                        #else
                        showingFullPlayer = true
                        #endif
                    }
                }
                // iPad per-platform presentation (Task 4): a large detented sheet on the detail
                // column. No-op on macOS (the Mac uses the dedicated player Window above).
                .iPadPlayerSheet(isPresented: $showingFullPlayer)
        }
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
        switch selection {
        case .search:
            NavigationStack { SearchView() }
        case .library(let library):
            NavigationStack { LibraryGridView(library: library) }
                .itemDetailDestination()
        case .series(let library):
            NavigationStack { SeriesListView(library: library) }
                .navigationDestination(for: SeriesSummary.self) { SeriesDetailView(library: library, series: $0) }
                .itemDetailDestination()
        case .authors(let library):
            NavigationStack { AuthorsListView(library: library) }
                .navigationDestination(for: AuthorSummary.self) { AuthorDetailView(library: library, author: $0) }
                .itemDetailDestination()
        case .home, .none:
            NavigationStack { HomeView() }
        }
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
