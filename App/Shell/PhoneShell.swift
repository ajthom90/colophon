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
                NavigationStack {
                    LibrariesView()
                        .navigationDestination(for: CachedLibrary.self) { LibraryItemsView(library: $0) }
                }
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
