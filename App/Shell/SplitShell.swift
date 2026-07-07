import SwiftUI
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
    // Optional so `List(selection:)` binds the single-selection sidebar initializer; `nil` falls
    // back to Home in the detail column.
    @State private var selection: SidebarItem? = .home
    @State private var libraries: [CachedLibrary] = []

    enum SidebarItem: Hashable {
        case home
        case search
        case library(CachedLibrary)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Home", systemImage: "house").tag(SidebarItem.home)
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                }
                Section("Libraries") {
                    ForEach(libraries) { library in
                        Label(library.name,
                              systemImage: library.mediaType == "podcast"
                                ? "antenna.radiowaves.left.and.right" : "books.vertical")
                            .tag(SidebarItem.library(library))
                    }
                }
            }
            .navigationTitle("Colophon")
            .accountMenu()
        } detail: {
            detailColumn
                .safeAreaInset(edge: .bottom) { TransportBar() }
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

    @ViewBuilder
    private var detailColumn: some View {
        // Each case owns its own `NavigationStack` so the detail column shows a title bar and
        // resets cleanly on selection change. LibraryItemsView plays a tapped book directly (no
        // push), so no `navigationDestination` is needed here.
        switch selection {
        case .search:
            NavigationStack { SearchPlaceholder() }
        case .library(let library):
            NavigationStack { LibraryItemsView(library: library) }
        case .home, .none:
            NavigationStack { HomePlaceholder() }
        }
    }
}

#if os(macOS)
/// Mac-only Playback command menu: `Space` play/pause, `⌘←`/`⌘→` skip (modifier-gated so plain
/// arrow-key list navigation in the sidebar is untouched), and a speed submenu — all wired to the
/// shared `PlaybackController` and disabled when no session is active. The full player UI is
/// M1c-b; these commands are valid now because the transport they drive already exists.
///
/// Space is unmodified (the media-app convention) and disabled with no session, so it does not
/// hijack the space bar while nothing is playing; note that with a session active it may take
/// precedence over a focused text field's space — acceptable for a media transport menu.
struct PlaybackCommands: Commands {
    var app: AppState
    private let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some Commands {
        CommandMenu("Playback") {
            Button(app.playback.isPlaying ? "Pause" : "Play") {
                app.playback.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(app.playback.totalDuration <= 0)

            Divider()

            Button("Skip Forward") {
                app.playback.skip(Double(app.playback.skipInterval))
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(app.playback.totalDuration <= 0)

            Button("Skip Back") {
                app.playback.skip(-Double(app.playback.skipInterval))
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(app.playback.totalDuration <= 0)

            Divider()

            Menu("Playback Speed") {
                ForEach(rates, id: \.self) { rate in
                    Button(String(format: "%g×", rate)) { app.playback.setRate(Float(rate)) }
                }
            }
            .disabled(app.playback.totalDuration <= 0)
        }
    }
}
#endif
