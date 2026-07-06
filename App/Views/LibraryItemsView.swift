import SwiftUI
import ABSKit

struct LibraryItemsView: View {
    @Environment(AppState.self) private var app
    let library: Library
    @State private var items: [LibraryItemSummary] = []
    @State private var total = 0
    @State private var page = 0
    private let pageSize = 50

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    Button {
                        Task { await app.startPlayback(item: item) }
                    } label: {
                        VStack(alignment: .leading) {
                            AsyncImage(url: app.client?.coverURL(itemID: item.id, width: 300, updatedAt: item.updatedAt)) { image in
                                image.resizable().aspectRatio(contentMode: .fit)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(item.media.metadata.title ?? "Untitled").font(.headline).lineLimit(2)
                            Text(item.media.metadata.authorName ?? "").font(.subheadline)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .padding()
        }
        .fontDesign(.serif)
        .navigationTitle(library.name)
        .task { await loadMore() }
    }

    private func loadMore() async {
        guard let client = app.client, items.count < total || page == 0 else { return }
        if let result = try? await client.items(libraryID: library.id, limit: pageSize, page: page) {
            items.append(contentsOf: result.results)
            total = result.total
            page += 1
        }
    }
}
