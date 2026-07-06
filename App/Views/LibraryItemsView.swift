import SwiftUI
import ABSKit
import LibraryCache

struct LibraryItemsView: View {
    @Environment(AppState.self) private var app
    let library: CachedLibrary
    @State private var items: [CachedItem] = []
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        Group {
            if items.isEmpty, let loadError {
                ContentUnavailableView {
                    Label("Couldn't load library", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Retry") { Task { await refresh() } }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            Button {
                                Task { await app.startPlayback(itemID: item.id) }
                            } label: {
                                VStack(alignment: .leading) {
                                    CachedCoverView(itemID: item.id, updatedAt: item.updatedAt)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(item.title).font(.headline).lineLimit(2)
                                    Text(item.authorName ?? "").font(.subheadline)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .fontDesign(.serif)
        .navigationTitle(library.name)
        .task(id: library.id) {
            do {
                for try await value in app.cache.observeItems(connectionID: library.connectionID, libraryID: library.id) {
                    items = value
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
        .task(id: library.id) { await refresh() }
    }

    private func refresh() async {
        loadError = nil
        do {
            try await app.refreshItems(libraryID: library.id)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
