import Foundation
import ABSKit

/// The write surface `Bookmarks` needs from the ABS client — narrowed to exactly the three
/// bookmark endpoints (Task 1) so the store's optimistic create/rename/delete logic is testable
/// against a trivial fake instead of a live `ABSClient`/network (mirrors how `SleepTimer` is
/// tested through the `SleepTimerHost` seam). `ABSClient` already exposes these signatures, so it
/// conforms as-is.
protocol BookmarkWriting: Sendable {
    func createBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark
    func updateBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark
    func deleteBookmark(itemID: String, time: Double) async throws
}

extension ABSClient: BookmarkWriting {}

/// The current book's bookmarks — created/renamed/deleted OPTIMISTICALLY against a local list and
/// mirrored to the server via the Task 1 endpoints, reconciled from `GET /api/me`'s `bookmarks[]`
/// on session start and on every progress refresh.
///
/// Owned by `AppState` (like `SleepTimer`), NOT recreated per view body, so the list survives the
/// bookmarks/player sheet being dismissed and re-presented. `AppState` points it at the active
/// client + now-playing item via `configure(...)` on `startPlayback`, and `clear()`s it on session
/// retire; the player's `BookmarksView` reads/mutates it.
///
/// ## Caching decision (recorded — coordinates with Task 7's v3 migration)
/// Bookmarks are IN-MEMORY + `me()`-sourced for M1c-b: they are deliberately NOT persisted to
/// `LibraryCache`. This is the lower-risk of the two options the plan offered — it adds NO
/// bookmarks table to a v3 migration, so **Task 7 owns the `v3` migration alone** (per-book speed)
/// with zero schema collision, and the frozen v1/v2 discipline is untouched. Offline bookmark
/// viewing (a `cachedBookmark` table) is filed as a post-v1 follow-up.
///
/// ## Optimistic + reconcile ordering
/// Every mutation updates the local list immediately, then calls the server and either confirms
/// with the server's own returned `Bookmark` (create/rename) or leaves the local edit in place
/// (delete). On failure it ROLLS BACK the local change and surfaces `errorMessage`. `upsert` keys
/// by `time` (the server's own composite key with `libraryItemId`), so a `reconcile` that lands
/// between an optimistic insert and its confirmation never leaves a duplicate — the confirmed
/// bookmark replaces (or re-adds) the row by time.
@Observable
@MainActor
final class Bookmarks {
    /// The current book's bookmarks, sorted by `time` ascending — the `List`'s render order.
    private(set) var items: [Bookmark] = []
    /// Transient error surfaced by `BookmarksView` (an alert) after a failed server op + rollback.
    var errorMessage: String?

    /// The now-playing item these bookmarks belong to, and the client to mutate them through —
    /// both set by `AppState.startPlayback` via `configure`, cleared on `retireCurrentSession`.
    private var itemID: String?
    private var writer: BookmarkWriting?

    init() {}

    /// Point the store at the active session's client + item. Clears any stale list from a
    /// previous book; the fresh list arrives via `reconcile` once `me()` returns.
    func configure(writer: BookmarkWriting, itemID: String) {
        self.writer = writer
        self.itemID = itemID
        items = []
        errorMessage = nil
    }

    /// Empty the store when the session is retired (book closed / signed out).
    func clear() {
        writer = nil
        itemID = nil
        items = []
        errorMessage = nil
    }

    /// Replace the list from `GET /api/me`'s `bookmarks[]`, filtered to `forItemID` and sorted by
    /// time. Called on session start and on `refreshProgress` while a book is playing. A stale
    /// `me()` for a DIFFERENT book than the one currently configured is ignored.
    func reconcile(from all: [Bookmark], forItemID: String) {
        guard forItemID == itemID else { return }
        items = Self.sorted(all.filter { $0.libraryItemId == forItemID })
    }

    // MARK: - Optimistic mutations (local first, then server; roll back on failure)

    /// Create a bookmark at `time` (fractional seconds — passed straight through to the server,
    /// which keys bookmarks by exact time). No-op if one already exists at that exact time.
    func create(atTime time: Double, title: String) async {
        guard let writer, let itemID else { return }
        guard !items.contains(where: { $0.time == time }) else { return }
        upsert(Bookmark(libraryItemId: itemID, time: time, title: title, createdAt: nil))
        do {
            let created = try await writer.createBookmark(itemID: itemID, time: time, title: title)
            upsert(created)                              // confirm with the server's canonical row
        } catch {
            remove(matchingTime: time)                   // roll back the optimistic insert
            errorMessage = Self.message(error)
        }
    }

    /// Rename a bookmark (PATCH, keyed by its exact `time`).
    func rename(_ bookmark: Bookmark, to newTitle: String) async {
        guard let writer, let itemID, let time = bookmark.time else { return }
        upsert(Bookmark(libraryItemId: itemID, time: time, title: newTitle, createdAt: bookmark.createdAt))
        do {
            let updated = try await writer.updateBookmark(itemID: itemID, time: time, title: newTitle)
            upsert(updated)
        } catch {
            upsert(bookmark)                             // roll back to the pre-rename row
            errorMessage = Self.message(error)
        }
    }

    /// Delete a bookmark (DELETE, keyed by its exact `time`).
    func delete(_ bookmark: Bookmark) async {
        guard let writer, let itemID, let time = bookmark.time else { return }
        remove(matchingTime: time)
        do {
            try await writer.deleteBookmark(itemID: itemID, time: time)
        } catch {
            upsert(bookmark)                             // roll back the optimistic removal
            errorMessage = Self.message(error)
        }
    }

    // MARK: - List helpers

    /// Insert-or-replace by `time` (the server's composite key), keeping the list time-sorted.
    private func upsert(_ bookmark: Bookmark) {
        var next = items.filter { $0.time != bookmark.time }
        next.append(bookmark)
        items = Self.sorted(next)
    }

    private func remove(matchingTime time: Double?) {
        items = items.filter { $0.time != time }
    }

    static func sorted(_ list: [Bookmark]) -> [Bookmark] {
        list.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
