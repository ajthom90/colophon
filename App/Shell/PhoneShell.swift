import SwiftUI
import LibraryCache

/// iPhone shell: a `TabView` (system Liquid Glass tab bar, free) with Home / Library / Search /
/// Downloads tabs, a now-playing `MiniPlayerBar` in the bottom accessory (sits above the tab bar,
/// shares its glass), and `.onScrollDown` tab-bar minimization. For Task 6 the tab contents are
/// placeholders except Library, which wires the existing library browser so a book can be played
/// and the mini-bar exercised.
struct PhoneShell: View {
    @State private var showingFullPlayer = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack {
                    HomeView()
                        .accountMenu()
                }
            }
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack { LibraryTabContent() }
            }
            Tab("Downloads", systemImage: "arrow.down.circle") {
                NavigationStack { DownloadsPlaceholder() }
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                NavigationStack { SearchPlaceholder() }
            }
        }
        .phoneTabChrome { MiniPlayerBar { showingFullPlayer = true } }
        .sheet(isPresented: $showingFullPlayer) { FullPlayerSheet() }
    }
}

/// The iPhone Library tab's content: shows the active (first) library's `LibraryGridView`, with a
/// toolbar library picker when the connection has more than one library (the plan's "keep it
/// simple: Library shows the active/first library's grid, with a library picker if >1"). Observes
/// the connection's cached library list so it tracks connection switches and resets cleanly.
private struct LibraryTabContent: View {
    @Environment(AppState.self) private var app
    @State private var libraries: [CachedLibrary] = []
    @State private var selectedID: String?

    private var selected: CachedLibrary? {
        libraries.first { $0.id == selectedID } ?? libraries.first
    }

    var body: some View {
        Group {
            if let library = selected {
                LibraryGridView(
                    library: library,
                    siblings: libraries,
                    onSelectLibrary: { selectedID = $0.id })
            } else {
                ContentUnavailableView {
                    Label("No Libraries", systemImage: "books.vertical")
                } description: {
                    Text("This connection has no libraries yet.")
                }
                .navigationTitle("Library")
            }
        }
        .task(id: app.activeConnectionID) {
            libraries = []
            selectedID = nil
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
