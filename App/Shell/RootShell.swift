import SwiftUI

/// Per-platform navigation shell, shown by `ColophonApp` once a connection is active. It selects
/// the idiomatic container for the current platform / size class: a compact-width iPhone gets
/// `PhoneShell` (a `TabView` with a bottom-accessory mini-player); iPad and Mac get `SplitShell`
/// (a `NavigationSplitView`, with a hand-built docked transport on the Mac).
///
/// Liquid Glass discipline (a review criterion): glass lives ONLY on the floating navigation /
/// transport chrome the shells build — and on the system chrome (tab bar, split-view sidebar),
/// which gets platform glass for free and is never re-skinned. Shelves, artwork, list rows and
/// text stay OPAQUE content; never glass-on-glass; at most one tinted `.glassProminent` primary
/// (the play/pause) per transport surface.
struct RootShell: View {
    #if os(macOS)
    // macOS windows are always regular-width, and `tabViewBottomAccessory` isn't available on
    // native macOS — the Mac always uses the split-view shell with its docked transport.
    var body: some View { SplitShell() }
    #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // Compact width == iPhone (or a narrow iPad multitasking slice) → the tab shell; regular
        // width == iPad → the split shell.
        if horizontalSizeClass == .compact {
            PhoneShell()
        } else {
            SplitShell()
        }
    }
    #endif
}

// MARK: - Placeholders (filled by later M1c-a tasks)

/// Search surface placeholder — the FTS5 ⨯ server blend lands in Task 10.
struct SearchPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("Search — M1c-a Task 10", systemImage: "magnifyingglass")
        } description: {
            Text("Blended local and server search arrives in a later task.")
        }
        .navigationTitle("Search")
    }
}

/// Downloads tab stub — offline downloads are a later-milestone (M2) feature.
struct DownloadsPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("Coming in M2", systemImage: "arrow.down.circle")
        } description: {
            Text("Offline downloads arrive in a future milestone.")
        }
        .navigationTitle("Downloads")
    }
}

// MARK: - Account menu (Connections / Settings access from within the shell)

/// A toolbar account menu shared by both shells so the multi-server hub and Settings stay
/// reachable once the shell has replaced `ConnectionsView` as the connected-phase root.
/// `ConnectionsView` is presented modally (it carries its own `NavigationStack` + Done button);
/// `SettingsView` is wrapped in a stack with a Done button. On the Mac, Settings is ALSO reachable
/// via the standard ⌘, `Settings` scene — this menu is the iPad/redundant path.
private struct AccountMenu: ViewModifier {
    @State private var showingConnections = false
    @State private var showingSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button { showingConnections = true } label: {
                            Label("Connections…", systemImage: "server.rack")
                        }
                        Button { showingSettings = true } label: {
                            Label("Settings…", systemImage: "gearshape")
                        }
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showingConnections) {
                // `isModal` adds a Done button and suppresses the boot auto-resume so this behaves
                // as a server switcher rather than re-pushing the current library.
                ConnectionsView(isModal: true)
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
    }
}

extension View {
    /// Adds the shared Connections/Settings account menu to a navigation surface's toolbar.
    func accountMenu() -> some View { modifier(AccountMenu()) }
}
