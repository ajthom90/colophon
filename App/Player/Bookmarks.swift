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

    /// Monotonic "local state has moved on" counter — bumped on `configure`/`clear` and on every
    /// optimistic mutation. It's the staleness guard for `reconcile`: bookmarks carry no `lastUpdate`
    /// (unlike `mediaProgress`, whose last-write-wins uses one), so this counter is the clean analog.
    /// `AppState` snapshots it BEFORE its `me()` fetch and hands it back to `reconcile`, which drops a
    /// snapshot whose generation is stale — so a `me()` in flight before a create/rename/delete that
    /// lands AFTER the mutation's server confirm can't silently erase/resurrect/revert it.
    private(set) var generation = 0

    /// The now-playing item these bookmarks belong to, and the client to mutate them through —
    /// both set by `AppState.startPlayback` via `configure`, cleared on `retireCurrentSession`.
    private var itemID: String?
    private var writer: BookmarkWriting?

    init() {}

    /// Point the store at the active session's client + item. Clears any stale list from a
    /// previous book; the fresh list arrives via `reconcile` once `me()` returns. Bumps `generation`
    /// so any `me()` snapshot whose fetch began under the previous book is dropped as stale.
    func configure(writer: BookmarkWriting, itemID: String) {
        self.writer = writer
        self.itemID = itemID
        items = []
        errorMessage = nil
        generation &+= 1
    }

    /// Empty the store when the session is retired (book closed / signed out).
    func clear() {
        writer = nil
        itemID = nil
        items = []
        errorMessage = nil
        generation &+= 1
    }

    /// Replace the list from `GET /api/me`'s `bookmarks[]`, filtered to `forItemID` and sorted by
    /// time. Called on session start and on `refreshProgress` while a book is playing.
    ///
    /// Two staleness guards: (1) a `me()` for a DIFFERENT book than the one currently configured is
    /// ignored (`forItemID == itemID`); (2) when `expectedGeneration` is supplied — `AppState`
    /// snapshots `generation` BEFORE its `me()` fetch and passes it here — a snapshot that predates a
    /// local mutation (which bumped `generation`) is dropped, so it can't erase/resurrect/revert a
    /// just-confirmed create/rename/delete. `nil` (tests/callers that don't race) applies uncondi-
    /// tionally when the item matches.
    func reconcile(from all: [Bookmark], forItemID: String, expectedGeneration: Int? = nil) {
        guard forItemID == itemID else { return }
        if let expectedGeneration, expectedGeneration != generation { return }
        items = Self.sorted(all.filter { $0.libraryItemId == forItemID })
    }

    // MARK: - Optimistic mutations (local first, then server; roll back on failure)

    /// Create a bookmark at `time` (fractional seconds — passed straight through to the server,
    /// which keys bookmarks by exact time). No-op if one already exists at that exact time.
    ///
    /// The captured `capturedItemID` guards every write to `items` after the `await`: if the user
    /// switched to another book (or retired the session) while the POST was in flight, the confirm/
    /// rollback must NOT land the row in the list the UI now shows for a DIFFERENT book.
    func create(atTime time: Double, title: String) async {
        guard let writer, let capturedItemID = itemID else { return }
        guard !items.contains(where: { $0.time == time }) else { return }
        beginLocalMutation()
        upsert(Bookmark(libraryItemId: capturedItemID, time: time, title: title, createdAt: nil))
        do {
            let created = try await writer.createBookmark(itemID: capturedItemID, time: time, title: title)
            guard itemID == capturedItemID else { return }   // book switched mid-flight — don't leak
            upsert(created)                                  // confirm with the server's canonical row
        } catch {
            guard itemID == capturedItemID else { return }
            remove(matchingTime: time)                       // roll back the optimistic insert
            errorMessage = Self.message(error)
        }
    }

    /// Rename a bookmark (PATCH, keyed by its exact `time`).
    func rename(_ bookmark: Bookmark, to newTitle: String) async {
        guard let writer, let capturedItemID = itemID, let time = bookmark.time else { return }
        beginLocalMutation()
        upsert(Bookmark(libraryItemId: capturedItemID, time: time, title: newTitle, createdAt: bookmark.createdAt))
        do {
            let updated = try await writer.updateBookmark(itemID: capturedItemID, time: time, title: newTitle)
            guard itemID == capturedItemID else { return }
            upsert(updated)
        } catch {
            guard itemID == capturedItemID else { return }
            upsert(bookmark)                                 // roll back to the pre-rename row
            errorMessage = Self.message(error)
        }
    }

    /// Delete a bookmark (DELETE, keyed by its exact `time`).
    func delete(_ bookmark: Bookmark) async {
        guard let writer, let capturedItemID = itemID, let time = bookmark.time else { return }
        beginLocalMutation()
        remove(matchingTime: time)
        do {
            try await writer.deleteBookmark(itemID: capturedItemID, time: time)
        } catch {
            guard itemID == capturedItemID else { return }
            upsert(bookmark)                                 // roll back the optimistic removal
            errorMessage = Self.message(error)
        }
    }

    // MARK: - List helpers

    /// Mark the local list as having moved on (a new optimistic edit): bumps `generation` so any
    /// `me()` snapshot captured before this edit is dropped by `reconcile` as stale.
    private func beginLocalMutation() { generation &+= 1 }

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
