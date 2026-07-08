import SwiftUI
import ABSKit

/// The current book's bookmarks, presented as a native `[.medium, .large]` sheet from
/// `FullPlayerView`'s glass bookmark button. HIG-idiomatic like Apple Books' bookmarks: opaque
/// `List` rows (never glass), each a title + a `.monospacedDigit()` time; tap a row to seek there
/// and dismiss; swipe or context-menu to rename/delete; a toolbar `+` bookmarks the current spot.
/// Empty state is a native `ContentUnavailableView`.
///
/// Reads/mutates the shared, `AppState`-owned `Bookmarks` store (survives this sheet being
/// dismissed), and seeks the shared `PlaybackController` via a recreated-per-body `PlayerModel`.
struct BookmarksView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// The bookmark being renamed (drives the rename alert); nil when the alert is closed.
    @State private var renaming: Bookmark?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Bookmarks")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { addAtCurrentTime() } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Bookmark")
                    }
                }
                .alert("Rename Bookmark", isPresented: renameAlertPresented) {
                    TextField("Title", text: $renameText)
                    Button("Cancel", role: .cancel) { renaming = nil }
                    Button("Save") { commitRename() }
                } message: {
                    Text("Give this bookmark a name.")
                }
                .alert("Bookmark Error", isPresented: errorAlertPresented) {
                    Button("OK") { app.bookmarks.errorMessage = nil }
                } message: {
                    Text(app.bookmarks.errorMessage ?? "")
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fontDesign(.default)
    }

    // MARK: - Content (empty state vs. list)

    @ViewBuilder
    private var content: some View {
        if app.bookmarks.items.isEmpty {
            ContentUnavailableView(
                "No Bookmarks",
                systemImage: "bookmark",
                description: Text("Tap + to bookmark the current spot."))
        } else {
            List {
                ForEach(app.bookmarks.items) { bookmark in
                    Button { seek(to: bookmark) } label: {
                        row(bookmark)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await app.bookmarks.delete(bookmark) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { beginRename(bookmark) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        Button { beginRename(bookmark) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            Task { await app.bookmarks.delete(bookmark) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row (opaque — title + monospaced time)

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark.fill")
                .font(.body)
                .foregroundStyle(.tint)
            Text(displayTitle(bookmark))
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(PlayerModel.timeString(bookmark.time ?? 0))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func seek(to bookmark: Bookmark) {
        guard let time = bookmark.time else { return }
        PlayerModel(app: app).seek(toGlobal: time)
        dismiss()
    }

    private func addAtCurrentTime() {
        let time = app.playback.globalTime
        let title = Self.defaultTitle(time)
        Task { await app.bookmarks.create(atTime: time, title: title) }
    }

    private func beginRename(_ bookmark: Bookmark) {
        renameText = displayTitle(bookmark)
        renaming = bookmark
    }

    private func commitRename() {
        guard let bookmark = renaming else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !title.isEmpty, title != bookmark.title else { return }
        Task { await app.bookmarks.rename(bookmark, to: title) }
    }

    // MARK: - Helpers

    private func displayTitle(_ bookmark: Bookmark) -> String {
        if let title = bookmark.title, !title.isEmpty { return title }
        return Self.defaultTitle(bookmark.time ?? 0)
    }

    /// The default, editable title for a new (or untitled) bookmark: "Bookmark at M:SS".
    static func defaultTitle(_ time: Double) -> String {
        "Bookmark at " + PlayerModel.timeString(time)
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { app.bookmarks.errorMessage != nil },
            set: { if !$0 { app.bookmarks.errorMessage = nil } })
    }
}
