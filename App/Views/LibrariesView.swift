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
        .fontDesign(.serif)
        .navigationDestination(for: CachedLibrary.self) { LibraryItemsView(library: $0) }
        .task(id: app.activeConnectionID) {
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
