import Foundation
import Testing
@testable import LibraryCache

@Suite struct LibraryCacheStoreTests {
    private func makeStore() throws -> LibraryCacheStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LibraryCacheStore(databaseURL: dir.appending(path: "cache.sqlite"))
    }

    @Test func connectionsRoundTrip() throws {
        let store = try makeStore()
        let conn = CachedConnection(id: "C1", address: "http://s:1", name: "Home",
                                    username: "u", authMethod: "local", sortIndex: 0)
        try store.upsertConnection(conn)
        #expect(try store.connections() == [conn])
        var renamed = conn; renamed.name = "Home NAS"
        try store.upsertConnection(renamed)
        #expect(try store.connections() == [renamed])
    }

    @Test func itemsPageUpsertIsIdempotentAndOrdered() throws {
        let store = try makeStore()
        try store.upsertConnection(CachedConnection(id: "C1", address: "a", name: "n",
                                                    username: "u", authMethod: "local", sortIndex: 0))
        try store.upsertLibraries([CachedLibrary(id: "L1", connectionID: "C1", name: "Books",
                                                 mediaType: "book", displayOrder: 1)], connectionID: "C1")
        let a = CachedItem(id: "i1", connectionID: "C1", libraryID: "L1",
                           title: "Zebra", authorName: "A", duration: 10, updatedAt: 1)
        let b = CachedItem(id: "i2", connectionID: "C1", libraryID: "L1",
                           title: "Aardvark", authorName: "B", duration: 20, updatedAt: 1)
        try store.upsertItemsPage([a, b], connectionID: "C1", libraryID: "L1")
        try store.upsertItemsPage([a], connectionID: "C1", libraryID: "L1")   // re-page: no dupes
        let items = try store.items(connectionID: "C1", libraryID: "L1")
        #expect(items.map(\.id) == ["i2", "i1"])                              // title-ordered
    }

    @Test func progressUpsertKeepsNewest() throws {
        let store = try makeStore()
        let old = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                 currentTime: 10, isFinished: false, lastUpdate: 100)
        let newer = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                   currentTime: 99, isFinished: false, lastUpdate: 200)
        try store.upsertProgress(old)
        try store.upsertProgress(newer)
        try store.upsertProgress(old)   // stale write must NOT clobber newer
        #expect(try store.progress(connectionID: "C1", itemID: "i1")?.currentTime == 99)
    }

    @Test func episodesStoreIndependentProgress() throws {
        let store = try makeStore()
        let a = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: "e1",
                               currentTime: 10, isFinished: false, lastUpdate: 200)
        let b = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: "e2",
                               currentTime: 20, isFinished: true, lastUpdate: 300)
        try store.upsertProgress(a)
        try store.upsertProgress(b)
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "e1")?.currentTime == 10)
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "e2")?.currentTime == 20)
        let staleA = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: "e1",
                                    currentTime: 1, isFinished: false, lastUpdate: 100)
        try store.upsertProgress(staleA)   // stale write to episode A...
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "e1")?.currentTime == 10)
        // ...never touches episode B
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "e2")?.currentTime == 20)
        // book-style progress (no episode) is a distinct row, absent here
        #expect(try store.progress(connectionID: "C1", itemID: "i1") == nil)
    }

    @Test func ftsFindsByTitleAndAuthorPrefix() throws {
        let store = try makeStore()
        try store.upsertItemsPage([
            CachedItem(id: "i1", connectionID: "C1", libraryID: "L1",
                       title: "The Art of War", authorName: "Sun Tzu", duration: 1, updatedAt: 1),
            CachedItem(id: "i2", connectionID: "C1", libraryID: "L1",
                       title: "Dracula", authorName: "Bram Stoker", duration: 1, updatedAt: 1),
        ], connectionID: "C1", libraryID: "L1")
        #expect(try store.searchItems(connectionID: "C1", query: "art").map(\.id) == ["i1"])
        #expect(try store.searchItems(connectionID: "C1", query: "stok").map(\.id) == ["i2"])
        #expect(try store.searchItems(connectionID: "C1", query: "zzz").isEmpty)
    }

    @Test func observationEmitsOnWrite() async throws {
        let store = try makeStore()
        let observation = store.observeLibraries(connectionID: "C1")
        var iterator = observation.makeAsyncIterator()
        _ = try await iterator.next()                                          // initial (empty) emission
        try store.upsertLibraries([CachedLibrary(id: "L1", connectionID: "C1", name: "Books",
                                                 mediaType: "book", displayOrder: 1)], connectionID: "C1")
        let next = try await iterator.next()
        #expect(next?.map(\.id) == ["L1"])
    }

    @Test func sameServerIDsCoexistAcrossConnections() throws {
        let store = try makeStore()
        let a = CachedItem(id: "i1", connectionID: "C1", libraryID: "L1", title: "A", authorName: nil, duration: 1, updatedAt: 1)
        let b = CachedItem(id: "i1", connectionID: "C2", libraryID: "L1", title: "B", authorName: nil, duration: 1, updatedAt: 1)
        try store.upsertItemsPage([a], connectionID: "C1", libraryID: "L1")
        try store.upsertItemsPage([b], connectionID: "C2", libraryID: "L1")
        #expect(try store.items(connectionID: "C1", libraryID: "L1").map(\.title) == ["A"])
        #expect(try store.items(connectionID: "C2", libraryID: "L1").map(\.title) == ["B"])   // not clobbered
    }

    @Test func deleteItemRemovesRowAndFTS() throws {
        let store = try makeStore()
        try store.upsertItemsPage([CachedItem(id: "i1", connectionID: "C1", libraryID: "L1",
                                              title: "Dracula", authorName: nil, duration: 1, updatedAt: 1)],
                                  connectionID: "C1", libraryID: "L1")
        try store.deleteItem(connectionID: "C1", itemID: "i1")
        #expect(try store.items(connectionID: "C1", libraryID: "L1").isEmpty)
        #expect(try store.searchItems(connectionID: "C1", query: "drac").isEmpty)
    }

    @Test func replaceItemsReconcilesAbsentRows() throws {
        let store = try makeStore()
        let keep = CachedItem(id: "i1", connectionID: "C1", libraryID: "L1", title: "Keep", authorName: nil, duration: 1, updatedAt: 1)
        let gone = CachedItem(id: "i2", connectionID: "C1", libraryID: "L1", title: "Gone", authorName: nil, duration: 1, updatedAt: 1)
        let other = CachedItem(id: "i9", connectionID: "C2", libraryID: "L1", title: "OtherConn", authorName: nil, duration: 1, updatedAt: 1)
        try store.upsertItemsPage([keep, gone], connectionID: "C1", libraryID: "L1")
        try store.upsertItemsPage([other], connectionID: "C2", libraryID: "L1")
        try store.replaceItems([keep], connectionID: "C1", libraryID: "L1")
        #expect(try store.items(connectionID: "C1", libraryID: "L1").map(\.id) == ["i1"])
        #expect(try store.items(connectionID: "C2", libraryID: "L1").map(\.id) == ["i9"])     // scoped: untouched
    }

    @Test func progressBatchSkipsStaleAndUnchanged() throws {
        let store = try makeStore()
        try store.upsertProgress(CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                                currentTime: 50, isFinished: false, lastUpdate: 200))
        try store.upsertProgressBatch([
            CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil, currentTime: 10, isFinished: false, lastUpdate: 100), // stale
            CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil, currentTime: 50, isFinished: false, lastUpdate: 200), // unchanged (>= skips)
            CachedProgress(connectionID: "C1", itemID: "i2", episodeID: nil, currentTime: 7, isFinished: false, lastUpdate: 300),  // new
        ])
        #expect(try store.progress(connectionID: "C1", itemID: "i1")?.currentTime == 50)
        #expect(try store.progress(connectionID: "C1", itemID: "i2")?.currentTime == 7)
    }

    @Test func deleteConnectionCascadesButLeavesOthersIntact() throws {
        let store = try makeStore()
        // Seed two connections, each with a library, an item, and a progress row.
        for c in ["C1", "C2"] {
            try store.upsertConnection(CachedConnection(id: c, address: "http://\(c)", name: c,
                                                        username: "u", authMethod: "local", sortIndex: 0))
            try store.upsertLibraries([CachedLibrary(id: "L1", connectionID: c, name: "Books",
                                                     mediaType: "book", displayOrder: 0)], connectionID: c)
            try store.upsertItemsPage([CachedItem(id: "i1", connectionID: c, libraryID: "L1",
                                                  title: "Dracula-\(c)", authorName: nil, duration: 1, updatedAt: 1)],
                                      connectionID: c, libraryID: "L1")
            try store.upsertProgress(CachedProgress(connectionID: c, itemID: "i1", episodeID: nil,
                                                    currentTime: 5, isFinished: false, lastUpdate: 10))
        }

        try store.deleteConnection(connectionID: "C1")

        // C1: every row (connection, library, item, FTS, progress) gone.
        #expect(try store.connections().map(\.id) == ["C2"])
        #expect(try store.items(connectionID: "C1", libraryID: "L1").isEmpty)
        #expect(try store.searchItems(connectionID: "C1", query: "drac").isEmpty)
        #expect(try store.progress(connectionID: "C1", itemID: "i1") == nil)
        // C2: fully intact.
        #expect(try store.items(connectionID: "C2", libraryID: "L1").map(\.id) == ["i1"])
        #expect(try store.searchItems(connectionID: "C2", query: "drac").map(\.id) == ["i1"])
        #expect(try store.progress(connectionID: "C2", itemID: "i1")?.currentTime == 5)
    }

    @Test func corruptDatabaseFileRecoversFresh() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appending(path: "cache.sqlite")
        try Data("this is not a sqlite database".utf8).write(to: dbURL)
        let store = try LibraryCacheStore(databaseURL: dbURL)   // must not throw: delete-and-recreate
        #expect(try store.connections().isEmpty)
    }
}
