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

// MARK: - Offline indicator (M2a Task 7 — offline-aware browse)

/// A small, non-blocking top-docked label shown on Home/Library/Search while the ACTIVE connection's
/// server is KNOWN-unreachable (`app.isOffline` — see its doc) — those surfaces already fall back to
/// the cache/downloads (see `AppState.refreshItems`'s/`HomeView.loadShelves`'s/`SearchModel`'s
/// `isOffline` fast-paths, which skip a doomed network wait rather than spin), so this is purely
/// informational: never an alert, never blocking interaction. Keyed on the SAME `isOffline` the
/// guards use so all four agree — and so it does NOT flash during a healthy launch's initial probe
/// (when `isOnline` is transiently false but the server is fine). Deliberately NOT applied to the
/// Downloads tab/sidebar entry (`DownloadsView` is fully local — nothing there depends on the
/// network, so the banner would be redundant noise). Shared by both shells (`PhoneShell`'s three
/// network-backed tabs, `SplitShell`'s Home/Search/library detail cases) via the `.offlineIndicator()`
/// modifier below — mirrors `LibrariesView`'s own inline connection-offline banner, reused here as a
/// shell-level chrome element instead of being duplicated into every leaf view.
private struct OfflineIndicator: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top) {
            if app.isOffline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                    Text("Offline — showing cached content")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar, in: Capsule())
                .padding(.top, 6)
            }
        }
    }
}

extension View {
    /// Applies the shared offline indicator (see `OfflineIndicator`'s doc comment).
    func offlineIndicator() -> some View { modifier(OfflineIndicator()) }
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
