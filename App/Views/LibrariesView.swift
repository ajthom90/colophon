import SwiftUI
import ABSKit
import LibraryCache

struct LibrariesView: View {
    @Environment(AppState.self) private var app
    @State private var libraries: [CachedLibrary] = []

    var body: some View {
        List(libraries) { library in
            NavigationLink(library.name, value: library)
        }
        .navigationTitle("Libraries")
        // The `CachedLibrary` navigationDestination is declared at the NavigationStack root in
        // `ConnectionsView` (a destination registered from within another destination doesn't
        // resolve); this view only emits the `NavigationLink(value:)` above.
        .safeAreaInset(edge: .top) {
            // Connection-level offline indicator: cached rows are browsable but the server is
            // unreachable (or credentials went stale). A top inset (not an overlay) so it never
            // obscures the first library row. Retry re-probes the connection.
            if let id = app.activeConnectionID, !app.isOnline {
                RefreshBanner(message: app.needsSignIn.contains(id) ? "Sign-in needed to sync"
                                                                    : "Offline — showing cached library",
                              retry: { Task { await app.activateConnection(id) } })
            }
        }
        .task(id: app.activeConnectionID) {
            // Reset before observing so a connection switch never flashes the previous
            // connection's library rows while the new observation spins up.
            libraries = []
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
