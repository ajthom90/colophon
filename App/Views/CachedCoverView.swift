import SwiftUI
import LibraryCache
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders an item's cover through `AppState.coverStore` (ts-keyed disk cache) instead of
/// `AsyncImage` hitting the network on every appearance — a cache hit serves disk bytes with
/// no request at all, and once a cover has been seen it survives server disconnects.
struct CachedCoverView: View {
    @Environment(AppState.self) private var app
    let itemID: String
    let updatedAt: Int?

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
        }
        .task(id: "\(itemID)-\(updatedAt ?? 0)") {
            await load()
        }
    }

    private func load() async {
        // No client/connection yet (e.g. view appears mid-disconnect): leave the placeholder up.
        guard let client = app.client, let connectionID = app.activeConnectionID else { return }
        let coverURL = client.coverURL(itemID: itemID, width: 300, updatedAt: updatedAt)
        do {
            let data = try await app.coverStore.coverData(
                connectionID: connectionID, itemID: itemID, updatedAt: updatedAt
            ) {
                try await URLSession.shared.data(from: coverURL).0
            }
            #if os(macOS)
            guard let platformImage = NSImage(data: data) else { return }
            image = Image(nsImage: platformImage)
            #else
            guard let platformImage = UIImage(data: data) else { return }
            image = Image(uiImage: platformImage)
            #endif
        } catch {
            // Fetch/decode failure: keep showing the placeholder rather than an error state.
            image = nil
        }
    }
}
