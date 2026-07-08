import SwiftUI

/// The up-next queue (Task 8), presented as a native `[.medium, .large]` sheet from `FullPlayerView`'s
/// glass queue button. HIG-idiomatic like Music/Podcasts' "Playing Next": OPAQUE `List` rows (never
/// glass — glass is confined to the player's transport cluster), each a cover + title + author;
/// drag to reorder (`onMove`), swipe to remove (`onDelete`), a "Clear" action, and a "Play Next"
/// action that skips the current book straight to the front of the queue (or stops when it's empty).
/// Empty state is a native `ContentUnavailableView`.
///
/// Reads/reorders the shared, `AppState`-owned `PlaybackQueue` (survives this sheet being dismissed)
/// and advances playback via `AppState.advanceToNext`.
struct QueueView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Playing Next")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .primaryAction) {
                        if !app.queue.isEmpty { EditButton() }
                    }
                    #endif
                }
                .safeAreaInset(edge: .bottom) { actionBar }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fontDesign(.default)
    }

    // MARK: - Content (empty state vs. reorderable list)

    @ViewBuilder
    private var content: some View {
        if app.queue.isEmpty {
            ContentUnavailableView(
                "Nothing Up Next",
                systemImage: "text.line.first.and.arrowtriangle.forward",
                description: Text("Add books with “Play Next” or “Add to Queue.”"))
        } else {
            List {
                ForEach(app.queue.entries) { entry in
                    row(entry)
                }
                .onMove { app.queue.move(from: $0, to: $1) }
                .onDelete { app.queue.remove(at: $0) }
            }
        }
    }

    // MARK: - Row (opaque — cover + title + author)

    private func row(_ entry: QueueEntry) -> some View {
        HStack(spacing: 12) {
            CachedCoverView(itemID: entry.coverItemID, updatedAt: nil)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let author = entry.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Action bar (native, opaque — Clear + Play Next)

    private var actionBar: some View {
        HStack {
            Button(role: .destructive) {
                app.queue.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(app.queue.isEmpty)

            Spacer()

            // Skip the current book straight to the next queued item (or stop when the queue is
            // empty) — the manual counterpart to the book-finished auto-advance.
            Button {
                Task { await app.advanceToNext() }
            } label: {
                Label("Play Next", systemImage: "forward.end.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Skip to Next")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
