import SwiftUI
import ABSKit

struct LibrariesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List(app.libraries) { library in
            NavigationLink(library.name, value: library)
        }
        .navigationTitle("Libraries")
        .navigationDestination(for: Library.self) { LibraryItemsView(library: $0) }
    }
}
