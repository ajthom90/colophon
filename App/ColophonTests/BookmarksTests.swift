import Testing
import Foundation
import ABSKit
@testable import Colophon

/// Store/actions proof for `Bookmarks` (Task 6) — the optimistic create/rename/delete round-trip
/// plus the `me()`-sourced reconcile — driven against a trivial `BookmarkWriting` fake so there's
/// NO live `ABSClient`/network (mirrors how `SleepTimer` is proven through its `SleepTimerHost`
/// seam). Every op is awaited to completion, so the fake's recorded calls are read race-free.
@MainActor
struct BookmarksTests {

    /// Minimal `BookmarkWriting` fake: records each call and echoes back a server-canonical
    /// `Bookmark` (a non-nil `createdAt` distinguishes a confirmed row from the optimistic one),
    /// with per-verb failure switches to exercise the rollback paths.
    final class FakeWriter: BookmarkWriting, @unchecked Sendable {
        private(set) var calls: [String] = []
        var failCreate = false
        var failUpdate = false
        var failDelete = false

        func createBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark {
            calls.append("create(\(itemID),\(time),\(title))")
            if failCreate { throw ABSError.invalidResponse }
            return Bookmark(libraryItemId: itemID, time: time, title: title, createdAt: 999)
        }
        func updateBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark {
            calls.append("update(\(itemID),\(time),\(title))")
            if failUpdate { throw ABSError.invalidResponse }
            return Bookmark(libraryItemId: itemID, time: time, title: title, createdAt: 999)
        }
        func deleteBookmark(itemID: String, time: Double) async throws {
            calls.append("delete(\(itemID),\(time))")
            if failDelete { throw ABSError.invalidResponse }
        }
    }

    private func mark(_ item: String, _ time: Double, _ title: String) -> Bookmark {
        Bookmark(libraryItemId: item, time: time, title: title, createdAt: nil)
    }

    private func configured(_ writer: FakeWriter, item: String = "itemA") -> Bookmarks {
        let store = Bookmarks()
        store.configure(writer: writer, itemID: item)
        return store
    }

    // MARK: - Reconcile

    @Test func reconcileFiltersToConfiguredItemAndSorts() {
        let store = configured(FakeWriter(), item: "itemA")
        store.reconcile(from: [
            mark("itemA", 300, "Third"),
            mark("itemB", 10, "Other book"),
            mark("itemA", 100, "First"),
            mark("itemA", 200, "Second"),
        ], forItemID: "itemA")

        #expect(store.items.map(\.time) == [100, 200, 300])   // sorted, itemB filtered out
        #expect(store.items.map { $0.title ?? "" } == ["First", "Second", "Third"])
    }

    @Test func reconcileIgnoresAStaleItem() {
        let store = configured(FakeWriter(), item: "itemA")
        // A late `me()` for a DIFFERENT book than the one configured must not populate the list.
        store.reconcile(from: [mark("itemB", 50, "B")], forItemID: "itemB")
        #expect(store.items.isEmpty)
    }

    // MARK: - Create

    @Test func createInsertsAndConfirmsFromServer() async {
        let writer = FakeWriter()
        let store = configured(writer)

        await store.create(atTime: 42.5, title: "Bookmark at 0:42")

        #expect(store.items.count == 1)
        let created = store.items[0]
        #expect(created.time == 42.5)
        #expect(created.title == "Bookmark at 0:42")
        #expect(created.createdAt == 999)                 // replaced by the server's canonical row
        #expect(writer.calls == ["create(itemA,42.5,Bookmark at 0:42)"])
        #expect(store.errorMessage == nil)
    }

    @Test func createRollsBackOnFailure() async {
        let writer = FakeWriter(); writer.failCreate = true
        let store = configured(writer)

        await store.create(atTime: 42, title: "Nope")

        #expect(store.items.isEmpty)                       // optimistic insert rolled back
        #expect(store.errorMessage != nil)
    }

    @Test func createIsNoOpAtDuplicateTime() async {
        let writer = FakeWriter()
        let store = configured(writer)

        await store.create(atTime: 100, title: "One")
        await store.create(atTime: 100, title: "Dup")     // same exact time → ignored

        #expect(store.items.count == 1)
        #expect(store.items[0].title == "One")
        #expect(writer.calls == ["create(itemA,100.0,One)"])
    }

    // MARK: - Rename

    @Test func renameUpdatesAndConfirms() async {
        let writer = FakeWriter()
        let store = configured(writer)
        await store.create(atTime: 60, title: "Old")

        await store.rename(store.items[0], to: "New")

        #expect(store.items.count == 1)
        #expect(store.items[0].title == "New")
        #expect(writer.calls.last == "update(itemA,60.0,New)")
    }

    @Test func renameRollsBackOnFailure() async {
        let writer = FakeWriter()
        let store = configured(writer)
        await store.create(atTime: 60, title: "Old")
        writer.failUpdate = true

        await store.rename(store.items[0], to: "New")

        #expect(store.items[0].title == "Old")             // reverted to the pre-rename title
        #expect(store.errorMessage != nil)
    }

    // MARK: - Delete

    @Test func deleteRemovesAndConfirms() async {
        let writer = FakeWriter()
        let store = configured(writer)
        await store.create(atTime: 60, title: "Gone")

        await store.delete(store.items[0])

        #expect(store.items.isEmpty)
        #expect(writer.calls.last == "delete(itemA,60.0)")
    }

    @Test func deleteRollsBackOnFailure() async {
        let writer = FakeWriter()
        let store = configured(writer)
        await store.create(atTime: 60, title: "Keep")
        writer.failDelete = true

        await store.delete(store.items[0])

        #expect(store.items.count == 1)                    // restored after the failed DELETE
        #expect(store.items[0].title == "Keep")
        #expect(store.errorMessage != nil)
    }

    // MARK: - Round trip + lifecycle

    @Test func createRenameDeleteRoundTrip() async {
        let writer = FakeWriter()
        let store = configured(writer)

        await store.create(atTime: 12.3, title: "A")
        await store.rename(store.items[0], to: "B")
        await store.delete(store.items[0])

        #expect(store.items.isEmpty)
        #expect(writer.calls == [
            "create(itemA,12.3,A)",
            "update(itemA,12.3,B)",
            "delete(itemA,12.3)",
        ])
    }

    @Test func configureResetsAndClearEmpties() async {
        let writer = FakeWriter()
        let store = configured(writer, item: "itemA")
        await store.create(atTime: 5, title: "A")
        #expect(store.items.count == 1)

        // Switching to a new book resets the list; the fresh list arrives via reconcile.
        store.configure(writer: writer, itemID: "itemB")
        #expect(store.items.isEmpty)

        store.reconcile(from: [mark("itemB", 7, "B")], forItemID: "itemB")
        #expect(store.items.count == 1)

        store.clear()
        #expect(store.items.isEmpty)
        // After clear there's no writer/item, so a create is a no-op.
        await store.create(atTime: 9, title: "C")
        #expect(store.items.isEmpty)
    }
}
