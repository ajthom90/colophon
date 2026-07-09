import Foundation
import GRDB
import Testing
@testable import LibraryCache

@Suite struct LibraryCacheStoreTests {
    private func makeStore() throws -> LibraryCacheStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LibraryCacheStore(databaseURL: dir.appending(path: "cache.sqlite"))
    }

    /// Builds a genuine v1-ONLY database file at `url`: a `DatabaseMigrator` registering ONLY
    /// "v1" (the exact frozen v1 schema, replicated with identical GRDB builders so the stored
    /// schema is byte-for-byte what production's v1 produced — this matters because the real
    /// store's DEBUG `eraseDatabaseOnSchemaChange` would wipe a mismatched v1 shape), a
    /// cachedItem row inserted with ONLY v1 columns (raw SQL — the v2 columns don't exist yet),
    /// then the writer is released (function return) so the file is closed before the real
    /// `LibraryCacheStore` reopens it and runs v1+v2. This exercises the ALTER against a real
    /// v1 table, which a fresh already-v1+v2 store never does.
    private func seedV1OnlyDatabase(at url: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "cachedConnection") { t in
                t.primaryKey("id", .text)
                t.column("address", .text).notNull()
                t.column("name", .text).notNull()
                t.column("username", .text).notNull()
                t.column("authMethod", .text).notNull()
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(table: "cachedLibrary") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("displayOrder", .integer).notNull()
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedItem") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("libraryID", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("authorName", .text)
                t.column("duration", .double)
                t.column("updatedAt", .integer)
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedProgress") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")
                t.column("currentTime", .double).notNull()
                t.column("isFinished", .boolean).notNull()
                t.column("lastUpdate", .integer).notNull()
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
            try db.create(virtualTable: "itemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "cachedItem")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("authorName")
            }
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cachedItem (id, connectionID, libraryID, title, authorName, duration, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["i1", "C1", "L1", "Dracula", "Bram Stoker", 100.0, 1])
        }
        try dbQueue.close()   // release the file so the real store can reopen it
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

    // MARK: - v2: item detail columns + podcast episodes

    /// Real forward-migration proof: seed an actual v1-ONLY database file (v1-only migrator +
    /// a raw-SQL cachedItem row), close it, then reopen through the production
    /// `LibraryCacheStore(databaseURL:)` — which runs v1 THEN v2, executing the `ALTER TABLE`
    /// against the pre-existing v1 table. Assert the v1 row survives with its original values,
    /// the six new v2 columns read back nil/empty, and the two new v2 tables now exist and are
    /// queryable.
    @Test func v2AddsDetailColumnsPreservingV1Rows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appending(path: "cache.sqlite")

        try seedV1OnlyDatabase(at: dbURL)                       // genuine v1-only file on disk
        let store = try LibraryCacheStore(databaseURL: dbURL)   // reopen → runs v1+v2 (ALTER on real v1 table)

        // The pre-existing v1 row survives, values intact.
        let fetched = try store.items(connectionID: "C1", libraryID: "L1").first
        #expect(fetched?.id == "i1")
        #expect(fetched?.title == "Dracula")
        #expect(fetched?.authorName == "Bram Stoker")
        #expect(fetched?.duration == 100)
        #expect(fetched?.updatedAt == 1)
        // The six ADD-COLUMN v2 fields back-fill as nil/empty for the existing row.
        #expect(fetched?.subtitle == nil)
        #expect(fetched?.narratorName == nil)
        #expect(fetched?.seriesName == nil)
        #expect(fetched?.genres == [])
        #expect(fetched?.publishedYear == nil)
        #expect(fetched?.descriptionSnippet == nil)
        // The two new v2 tables exist and are queryable (a missing table would throw), and
        // round-trip real rows.
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1") == nil)
        #expect(try store.episodes(connectionID: "C1", itemID: "i1").isEmpty)
        try store.upsertItemDetail(CachedItemDetail(connectionID: "C1", itemID: "i1", publisher: "Acme"))
        try store.upsertEpisodes([CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e1",
                                                publishedAt: 1)], connectionID: "C1", itemID: "i1")
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1")?.publisher == "Acme")
        #expect(try store.episodes(connectionID: "C1", itemID: "i1").map(\.episodeID) == ["e1"])
    }

    @Test func itemDetailRoundTrips() throws {
        let store = try makeStore()
        let detail = CachedItemDetail(connectionID: "C1", itemID: "i1",
                                      description: "Full description", publisher: "Acme Pub",
                                      isbn: "isbn1", asin: "asin1", language: "en",
                                      explicit: false, abridged: true, publishedDate: "2020-01-01",
                                      chapters: [CachedChapter(id: 1, start: 0, end: 120, title: "Ch1"),
                                                 CachedChapter(id: 2, start: 120, end: 240, title: "Ch2")])
        try store.upsertItemDetail(detail)

        let fetched = try store.itemDetail(connectionID: "C1", itemID: "i1")
        #expect(fetched?.description == "Full description")
        #expect(fetched?.publisher == "Acme Pub")
        #expect(fetched?.isbn == "isbn1")
        #expect(fetched?.asin == "asin1")
        #expect(fetched?.language == "en")
        #expect(fetched?.explicit == false)
        #expect(fetched?.abridged == true)
        #expect(fetched?.publishedDate == "2020-01-01")
        #expect(fetched?.chapters == [CachedChapter(id: 1, start: 0, end: 120, title: "Ch1"),
                                       CachedChapter(id: 2, start: 120, end: 240, title: "Ch2")])

        // upsert replaces in place (1:1 with item — no accretion of duplicate rows).
        var updated = detail
        updated.publisher = "Second Pub"
        try store.upsertItemDetail(updated)
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1")?.publisher == "Second Pub")

        #expect(try store.itemDetail(connectionID: "C1", itemID: "missing") == nil)
    }

    @Test func episodesRoundTripSortedByPublishedAtDesc() throws {
        let store = try makeStore()
        let e1 = CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e1",
                               title: "First", publishedAt: 100)
        let e2 = CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e2",
                               title: "Second", publishedAt: 300)
        let e3 = CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e3",
                               title: "Third", publishedAt: 200)
        try store.upsertEpisodes([e1, e2, e3], connectionID: "C1", itemID: "i1")   // inserted out of order

        let fetched = try store.episodes(connectionID: "C1", itemID: "i1")
        #expect(fetched.map(\.episodeID) == ["e2", "e3", "e1"])   // 300, 200, 100 -> DESC
    }

    /// Every `CachedEpisode` column round-trips through the DB unchanged — in particular `season`/
    /// `episode` stay STRINGS ("1"/"2", not coerced to/from integers), matching the live
    /// `PodcastEpisode` shape (M1c-c Task 1/2) the `AppState.refreshPodcastEpisodes` mapping feeds
    /// this table from.
    @Test func episodeFieldsRoundTripWithStringSeasonAndEpisode() throws {
        let store = try makeStore()
        let full = CachedEpisode(
            connectionID: "C1", itemID: "i1", episodeID: "e1",
            idx: 3, season: "1", episode: "2", episodeType: "full",
            title: "Episode Two: Attack by Stratagem", subtitle: "Winning without fighting",
            episodeDescription: "<p>HTML description</p>", pubDate: "Mon, 13 Jan 2025 08:00:00 GMT",
            publishedAt: 1736755200000, durationSeconds: 506.827755, sizeBytes: 4055751,
            guid: "colophon-test-ep-0002")
        try store.upsertEpisodes([full], connectionID: "C1", itemID: "i1")

        let fetched = try #require(try store.episodes(connectionID: "C1", itemID: "i1").first)
        #expect(fetched.idx == 3)
        #expect(fetched.season == "1")
        #expect(fetched.episode == "2")
        #expect(fetched.episodeType == "full")
        #expect(fetched.title == "Episode Two: Attack by Stratagem")
        #expect(fetched.subtitle == "Winning without fighting")
        #expect(fetched.episodeDescription == "<p>HTML description</p>")
        #expect(fetched.pubDate == "Mon, 13 Jan 2025 08:00:00 GMT")
        #expect(fetched.publishedAt == 1736755200000)
        #expect(fetched.durationSeconds == 506.827755)
        #expect(fetched.sizeBytes == 4055751)
        #expect(fetched.guid == "colophon-test-ep-0002")
    }

    @Test func upsertEpisodesReplacesScopedToItem() throws {
        let store = try makeStore()
        let aKeep = CachedEpisode(connectionID: "C1", itemID: "A", episodeID: "a1", publishedAt: 1)
        let aGone = CachedEpisode(connectionID: "C1", itemID: "A", episodeID: "a2", publishedAt: 2)
        let bItem = CachedEpisode(connectionID: "C1", itemID: "B", episodeID: "b1", publishedAt: 1)
        try store.upsertEpisodes([aKeep, aGone], connectionID: "C1", itemID: "A")
        try store.upsertEpisodes([bItem], connectionID: "C1", itemID: "B")

        try store.upsertEpisodes([aKeep], connectionID: "C1", itemID: "A")   // replace: aGone dropped

        #expect(try store.episodes(connectionID: "C1", itemID: "A").map(\.episodeID) == ["a1"])
        #expect(try store.episodes(connectionID: "C1", itemID: "B").map(\.episodeID) == ["b1"])   // untouched
    }

    /// An empty replacement set wipes exactly that item's episodes (a podcast whose feed lost
    /// all episodes), leaving other items untouched.
    @Test func upsertEpisodesEmptyArrayWipesItem() throws {
        let store = try makeStore()
        try store.upsertEpisodes([CachedEpisode(connectionID: "C1", itemID: "A", episodeID: "a1", publishedAt: 1),
                                  CachedEpisode(connectionID: "C1", itemID: "A", episodeID: "a2", publishedAt: 2)],
                                 connectionID: "C1", itemID: "A")
        try store.upsertEpisodes([CachedEpisode(connectionID: "C1", itemID: "B", episodeID: "b1", publishedAt: 1)],
                                 connectionID: "C1", itemID: "B")

        try store.upsertEpisodes([], connectionID: "C1", itemID: "A")   // empty set: wipe item A's episodes

        #expect(try store.episodes(connectionID: "C1", itemID: "A").isEmpty)
        #expect(try store.episodes(connectionID: "C1", itemID: "B").map(\.episodeID) == ["b1"])   // untouched
    }

    @Test func deleteConnectionPurgesDetailAndEpisodes() throws {
        let store = try makeStore()
        for c in ["C1", "C2"] {
            try store.upsertItemsPage([CachedItem(id: "i1", connectionID: c, libraryID: "L1",
                                                  title: "Item-\(c)", authorName: nil, duration: 1, updatedAt: 1)],
                                      connectionID: c, libraryID: "L1")
            try store.upsertItemDetail(CachedItemDetail(connectionID: c, itemID: "i1", publisher: "Pub-\(c)"))
            try store.upsertEpisodes([CachedEpisode(connectionID: c, itemID: "i1", episodeID: "e1", publishedAt: 1)],
                                     connectionID: c, itemID: "i1")
        }

        try store.deleteConnection(connectionID: "C1")

        // C1: item, detail, and episode rows all gone — no orphaned cache.
        #expect(try store.items(connectionID: "C1", libraryID: "L1").isEmpty)
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1") == nil)
        #expect(try store.episodes(connectionID: "C1", itemID: "i1").isEmpty)
        // C2: fully intact.
        #expect(try store.items(connectionID: "C2", libraryID: "L1").map(\.id) == ["i1"])
        #expect(try store.itemDetail(connectionID: "C2", itemID: "i1")?.publisher == "Pub-C2")
        #expect(try store.episodes(connectionID: "C2", itemID: "i1").map(\.episodeID) == ["e1"])
    }

    @Test func deleteItemPurgesDetailAndEpisodes() throws {
        let store = try makeStore()
        for id in ["i1", "i2"] {
            try store.upsertItemsPage([CachedItem(id: id, connectionID: "C1", libraryID: "L1",
                                                  title: "Item-\(id)", authorName: nil, duration: 1, updatedAt: 1)],
                                      connectionID: "C1", libraryID: "L1")
            try store.upsertItemDetail(CachedItemDetail(connectionID: "C1", itemID: id, publisher: "Pub-\(id)"))
            try store.upsertEpisodes([CachedEpisode(connectionID: "C1", itemID: id, episodeID: "e1", publishedAt: 1)],
                                     connectionID: "C1", itemID: id)
        }

        try store.deleteItem(connectionID: "C1", itemID: "i1")

        // i1: item, detail, and episode rows all gone.
        #expect(try store.items(connectionID: "C1", libraryID: "L1").map(\.id) == ["i2"])
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1") == nil)
        #expect(try store.episodes(connectionID: "C1", itemID: "i1").isEmpty)
        // i2: detail and episodes untouched.
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i2")?.publisher == "Pub-i2")
        #expect(try store.episodes(connectionID: "C1", itemID: "i2").map(\.episodeID) == ["e1"])
    }

    /// Sanity that adding `cachedEpisode` didn't disturb the M1b `cachedProgress` 3-part PK —
    /// two episodes of the same item still track independent progress.
    @Test func episodeProgressStillKeyedPerEpisode() throws {
        let store = try makeStore()
        try store.upsertEpisodes([
            CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e1", publishedAt: 1),
            CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e2", publishedAt: 2),
        ], connectionID: "C1", itemID: "i1")
        try store.upsertProgress(CachedProgress(connectionID: "C1", itemID: "i1", episodeID: "e1",
                                                currentTime: 10, isFinished: false, lastUpdate: 100))
        try store.upsertProgress(CachedProgress(connectionID: "C1", itemID: "i1", episodeID: "e2",
                                                currentTime: 20, isFinished: true, lastUpdate: 200))
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "e1")?.currentTime == 10)
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "e2")?.currentTime == 20)
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "e2")?.isFinished == true)
    }

    /// M1c-c Task 3: a book-style progress row (`episodeID: nil` → `""`) and a real episode
    /// progress row (`episodeID` populated, as `AppState.refreshProgress` writes from a `me()`
    /// entry whose `episodeId` is non-empty) coexist independently under the SAME connection+item
    /// — the 3-part PK keeps them distinct rows rather than one clobbering the other, and each is
    /// individually addressable via `progress(episodeID:)`. Extends `episodeProgressStillKeyedPerEpisode`
    /// (which only covered episode-vs-episode) with the book-vs-episode case.
    @Test func episodeProgressDistinctFromBookProgress() throws {
        let store = try makeStore()
        let bookRow = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                     currentTime: 500, isFinished: false, lastUpdate: 100)
        let episodeRow = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: "ep_1",
                                        currentTime: 30, isFinished: true, lastUpdate: 200)
        try store.upsertProgress(bookRow)
        try store.upsertProgress(episodeRow)

        let book = try #require(try store.progress(connectionID: "C1", itemID: "i1"))
        let episode = try #require(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "ep_1"))
        #expect(book.episodeID == "")
        #expect(book.currentTime == 500)
        #expect(book.isFinished == false)
        #expect(episode.episodeID == "ep_1")
        #expect(episode.currentTime == 30)
        #expect(episode.isFinished == true)

        // A stale re-write of the book row must not disturb the episode row, and vice versa.
        try store.upsertProgress(CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                                currentTime: 1, isFinished: false, lastUpdate: 1))
        #expect(try store.progress(connectionID: "C1", itemID: "i1")?.currentTime == 500)
        #expect(try store.progress(connectionID: "C1", itemID: "i1", episodeID: "ep_1")?.currentTime == 30)
    }

    /// `observeEpisodes` (M1c-c Task 3) mirrors `observeLibraries`'/`observeItems`'s live-stream
    /// role for the podcast-detail view: the initial emission reflects whatever's cached (empty
    /// for a never-fetched item), and an `upsertEpisodes` reconcile pushes a fresh emission with no
    /// refetch needed by the observer.
    @Test func observeEpisodesEmitsOnUpsert() async throws {
        let store = try makeStore()
        let observation = store.observeEpisodes(connectionID: "C1", itemID: "i1")
        var iterator = observation.makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == [])                                                  // nothing cached yet

        try store.upsertEpisodes([
            CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e1", title: "First", publishedAt: 100),
        ], connectionID: "C1", itemID: "i1")
        let afterUpsert = try await iterator.next()
        #expect(afterUpsert?.map(\.episodeID) == ["e1"])

        // A reconcile that drops e1 and adds e2 pushes another emission — scoped to this item only.
        try store.upsertEpisodes([
            CachedEpisode(connectionID: "C1", itemID: "i1", episodeID: "e2", title: "Second", publishedAt: 200),
        ], connectionID: "C1", itemID: "i1")
        let afterReplace = try await iterator.next()
        #expect(afterReplace?.map(\.episodeID) == ["e2"])
    }

    // MARK: - v3: per-book playback-rate preference (Task 7)

    /// Builds a genuine v1+v2-ONLY database file (registers ONLY "v1" and "v2", replicating the
    /// frozen migrations byte-for-byte — same discipline as `seedV1OnlyDatabase`, one migration
    /// further) with a real `cachedItem` row carrying v2 columns AND a `cachedItemDetail` row,
    /// then closes it. Reopening through the production `LibraryCacheStore` runs v1+v2+v3, so v3's
    /// `CREATE TABLE cachedItemPref` (additive — no `ALTER`) is proven against a genuinely
    /// pre-existing v1+v2 file rather than a fresh already-v3 store.
    private func seedV1V2OnlyDatabase(at url: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "cachedConnection") { t in
                t.primaryKey("id", .text)
                t.column("address", .text).notNull()
                t.column("name", .text).notNull()
                t.column("username", .text).notNull()
                t.column("authMethod", .text).notNull()
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(table: "cachedLibrary") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("displayOrder", .integer).notNull()
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedItem") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("libraryID", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("authorName", .text)
                t.column("duration", .double)
                t.column("updatedAt", .integer)
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedProgress") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")
                t.column("currentTime", .double).notNull()
                t.column("isFinished", .boolean).notNull()
                t.column("lastUpdate", .integer).notNull()
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
            try db.create(virtualTable: "itemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "cachedItem")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("authorName")
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "cachedItem") { t in
                t.add(column: "subtitle", .text)
                t.add(column: "narratorName", .text)
                t.add(column: "seriesName", .text)
                t.add(column: "genresJSON", .text)
                t.add(column: "publishedYear", .text)
                t.add(column: "descriptionSnippet", .text)
            }
            try db.create(table: "cachedItemDetail") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("description", .text)
                t.column("publisher", .text)
                t.column("isbn", .text)
                t.column("asin", .text)
                t.column("language", .text)
                t.column("explicit", .boolean)
                t.column("abridged", .boolean)
                t.column("publishedDate", .text)
                t.column("chaptersJSON", .text)
                t.primaryKey(["connectionID", "itemID"])
            }
            try db.create(table: "cachedEpisode") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull()
                t.column("idx", .integer)
                t.column("season", .text)
                t.column("episode", .text)
                t.column("episodeType", .text)
                t.column("title", .text)
                t.column("subtitle", .text)
                t.column("episodeDescription", .text)
                t.column("pubDate", .text)
                t.column("publishedAt", .integer)
                t.column("durationSeconds", .double)
                t.column("sizeBytes", .integer)
                t.column("guid", .text)
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cachedItem (id, connectionID, libraryID, title, authorName, duration, updatedAt,
                                         subtitle, narratorName, seriesName, genresJSON, publishedYear, descriptionSnippet)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["i1", "C1", "L1", "Dracula", "Bram Stoker", 100.0, 1,
                            "A Novel", "Narrator Name", "Gothic Classics", "[\"Horror\"]", "1897", "A count..."])
            try db.execute(sql: """
                INSERT INTO cachedItemDetail (connectionID, itemID, description, publisher)
                VALUES (?, ?, ?, ?)
                """,
                arguments: ["C1", "i1", "Full description", "Acme Pub"])
        }
        try dbQueue.close()   // release the file so the real store can reopen it
    }

    /// THE sabotage-provable v3 migration test (same rigor as `v2AddsDetailColumnsPreservingV1Rows`):
    /// seed a genuine v1+v2-only file, reopen through the production store (runs v1+v2+v3 — v3's
    /// `CREATE TABLE` executed against real pre-existing tables), and assert (1) the v1 row and its
    /// v2 columns survive untouched, (2) the v2 `cachedItemDetail` row survives, and (3) the new
    /// `cachedItemPref` table exists, is queryable, and round-trips a real row.
    @Test func v3AddsPrefTablePreservingV1V2Rows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appending(path: "cache.sqlite")

        try seedV1V2OnlyDatabase(at: dbURL)                     // genuine v1+v2-only file on disk
        let store = try LibraryCacheStore(databaseURL: dbURL)   // reopen → runs v1+v2+v3 (CREATE TABLE only)

        // The pre-existing v1 row + its v2 columns survive, values intact.
        let fetched = try store.items(connectionID: "C1", libraryID: "L1").first
        #expect(fetched?.id == "i1")
        #expect(fetched?.title == "Dracula")
        #expect(fetched?.authorName == "Bram Stoker")
        #expect(fetched?.subtitle == "A Novel")
        #expect(fetched?.narratorName == "Narrator Name")
        #expect(fetched?.seriesName == "Gothic Classics")
        #expect(fetched?.genres == ["Horror"])
        #expect(fetched?.publishedYear == "1897")
        // The pre-existing v2 detail row survives.
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1")?.publisher == "Acme Pub")
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1")?.description == "Full description")

        // The new v3 table exists, is queryable (a missing table would throw), and round-trips a
        // real row — absent by default, then set/read.
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == nil)
        try store.setPlaybackRate(1.5, connectionID: "C1", itemID: "i1")
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == 1.5)
    }

    @Test func playbackRateRoundTrips() throws {
        let store = try makeStore()
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == nil)
        try store.setPlaybackRate(1.5, connectionID: "C1", itemID: "i1")
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == 1.5)
        // nil clears back to the "no per-book rate" default.
        try store.setPlaybackRate(nil, connectionID: "C1", itemID: "i1")
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == nil)
    }

    @Test func playbackRateScopedPerItemAndConnection() throws {
        let store = try makeStore()
        try store.setPlaybackRate(1.25, connectionID: "C1", itemID: "i1")
        try store.setPlaybackRate(2.0, connectionID: "C1", itemID: "i2")
        try store.setPlaybackRate(0.75, connectionID: "C2", itemID: "i1")   // same itemID, other connection

        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == 1.25)
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i2") == 2.0)
        #expect(try store.playbackRate(connectionID: "C2", itemID: "i1") == 0.75)
    }

    // MARK: - v4: download records (Task 2)

    @Test func downloadRoundTripWithMultiFileChildren() throws {
        let store = try makeStore()
        let download = CachedDownload(connectionID: "C1", itemID: "i1", episodeID: nil,
                                      state: "downloading", receivedBytes: 50, totalBytes: 200, updatedAt: 100)
        try store.upsertDownload(download)
        try store.upsertDownloadFile(CachedDownloadFile(
            connectionID: "C1", itemID: "i1", trackIndex: 0, ino: "ino1",
            localRelativePath: "C1/i1/track-0.m4b", receivedBytes: 50, totalBytes: 100,
            state: "downloaded", mimeType: "audio/mp4"))
        try store.upsertDownloadFile(CachedDownloadFile(
            connectionID: "C1", itemID: "i1", trackIndex: 1, ino: "ino2",
            localRelativePath: "C1/i1/track-1.m4b", receivedBytes: 0, totalBytes: 100, state: "queued"))

        let fetched = try #require(try store.download(connectionID: "C1", itemID: "i1"))
        #expect(fetched.download.state == "downloading")
        #expect(fetched.download.receivedBytes == 50)
        #expect(fetched.download.totalBytes == 200)
        #expect(fetched.files.map(\.trackIndex) == [0, 1])
        // Per-file relative paths preserved exactly — RELATIVE, not absolute.
        #expect(fetched.files[0].localRelativePath == "C1/i1/track-0.m4b")
        #expect(fetched.files[1].localRelativePath == "C1/i1/track-1.m4b")
        #expect(fetched.files[0].ino == "ino1")
        #expect(fetched.files[0].state == "downloaded")
        #expect(fetched.files[0].mimeType == "audio/mp4")
        #expect(fetched.files[1].state == "queued")

        #expect(try store.download(connectionID: "C1", itemID: "missing") == nil)
    }

    /// A podcast-episode download (`episodeID` non-empty) and a book-level download (`episodeID`
    /// `""`) coexist independently under the SAME connection+item — mirrors
    /// `episodeProgressDistinctFromBookProgress`'s proof for `cachedProgress`.
    @Test func episodeDownloadDistinctFromBookDownload() throws {
        let store = try makeStore()
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", episodeID: nil,
                                                state: "downloaded", receivedBytes: 100, totalBytes: 100, updatedAt: 1))
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", episodeID: "e1",
                                                state: "queued", updatedAt: 2))

        #expect(try store.download(connectionID: "C1", itemID: "i1")?.download.state == "downloaded")
        #expect(try store.download(connectionID: "C1", itemID: "i1", episodeID: "e1")?.download.state == "queued")
    }

    @Test func downloadsListsAllForConnectionNewestFirst() throws {
        let store = try makeStore()
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", state: "downloaded", updatedAt: 100))
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i2", episodeID: "e1", state: "queued", updatedAt: 200))
        try store.upsertDownload(CachedDownload(connectionID: "C2", itemID: "i9", state: "downloaded", updatedAt: 50))

        #expect(try store.downloads(connectionID: "C1").map(\.itemID) == ["i2", "i1"])   // newest updatedAt first
        #expect(try store.downloads(connectionID: "C2").map(\.itemID) == ["i9"])          // scoped: untouched
    }

    @Test func observeDownloadsEmitsOnUpsert() async throws {
        let store = try makeStore()
        let observation = store.observeDownloads(connectionID: "C1")
        var iterator = observation.makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == [])                                                   // nothing cached yet

        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", state: "queued", updatedAt: 1))
        let afterEnqueue = try await iterator.next()
        #expect(afterEnqueue?.map(\.itemID) == ["i1"])
        #expect(afterEnqueue?.first?.state == "queued")

        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", state: "downloaded",
                                                receivedBytes: 100, totalBytes: 100, updatedAt: 2))
        let afterComplete = try await iterator.next()
        #expect(afterComplete?.first?.state == "downloaded")
        #expect(afterComplete?.first?.receivedBytes == 100)
    }

    @Test func deleteDownloadRemovesParentAndFiles() throws {
        let store = try makeStore()
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", state: "downloaded",
                                                receivedBytes: 200, totalBytes: 200, updatedAt: 1))
        try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C1", itemID: "i1", trackIndex: 0,
                                                         ino: "ino1", localRelativePath: "p0",
                                                         receivedBytes: 100, totalBytes: 100, state: "downloaded"))
        try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C1", itemID: "i1", trackIndex: 1,
                                                         ino: "ino2", localRelativePath: "p1",
                                                         receivedBytes: 100, totalBytes: 100, state: "downloaded"))
        // An unrelated download must survive the delete.
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i2", state: "downloaded",
                                                receivedBytes: 50, totalBytes: 50, updatedAt: 1))
        try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C1", itemID: "i2", trackIndex: 0,
                                                         ino: "ino9", localRelativePath: "p9",
                                                         receivedBytes: 50, totalBytes: 50, state: "downloaded"))

        try store.deleteDownload(connectionID: "C1", itemID: "i1")

        #expect(try store.download(connectionID: "C1", itemID: "i1") == nil)
        #expect(try store.download(connectionID: "C1", itemID: "i2")?.files.count == 1)   // untouched
        #expect(try store.totalDownloadedBytes(connectionID: "C1") == 50)                 // only i2's file remains
    }

    @Test func totalDownloadedBytesSumsFileRowsPerConnection() throws {
        let store = try makeStore()
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", state: "downloading",
                                                receivedBytes: 150, totalBytes: 300, updatedAt: 1))
        try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C1", itemID: "i1", trackIndex: 0,
                                                         ino: "ino1", localRelativePath: "p0",
                                                         receivedBytes: 100, totalBytes: 100, state: "downloaded"))
        try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C1", itemID: "i1", trackIndex: 1,
                                                         ino: "ino2", localRelativePath: "p1",
                                                         receivedBytes: 50, totalBytes: 200, state: "downloading"))
        try store.upsertDownload(CachedDownload(connectionID: "C2", itemID: "i9", state: "downloaded",
                                                receivedBytes: 999, totalBytes: 999, updatedAt: 1))
        try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C2", itemID: "i9", trackIndex: 0,
                                                         ino: "ino9", localRelativePath: "p9",
                                                         receivedBytes: 999, totalBytes: 999, state: "downloaded"))

        #expect(try store.totalDownloadedBytes(connectionID: "C1") == 150)
        #expect(try store.totalDownloadedBytes(connectionID: "C2") == 999)
        #expect(try store.totalDownloadedBytes(connectionID: "C3") == 0)   // no downloads at all
    }

    @Test func deleteConnectionCascadesToDownloads() throws {
        let store = try makeStore()
        for c in ["C1", "C2"] {
            try store.upsertDownload(CachedDownload(connectionID: c, itemID: "i1", state: "downloaded",
                                                    receivedBytes: 10, totalBytes: 10, updatedAt: 1))
            try store.upsertDownloadFile(CachedDownloadFile(connectionID: c, itemID: "i1", trackIndex: 0,
                                                             ino: "ino-\(c)", localRelativePath: "p-\(c)",
                                                             receivedBytes: 10, totalBytes: 10, state: "downloaded"))
        }

        try store.deleteConnection(connectionID: "C1")

        // C1: parent + file rows gone.
        #expect(try store.download(connectionID: "C1", itemID: "i1") == nil)
        #expect(try store.totalDownloadedBytes(connectionID: "C1") == 0)
        // C2: fully intact.
        #expect(try store.download(connectionID: "C2", itemID: "i1")?.download.state == "downloaded")
        #expect(try store.totalDownloadedBytes(connectionID: "C2") == 10)
    }

    @Test func deleteItemCascadesToDownloads() throws {
        let store = try makeStore()
        for id in ["i1", "i2"] {
            try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: id, state: "downloaded",
                                                    receivedBytes: 10, totalBytes: 10, updatedAt: 1))
            try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C1", itemID: id, trackIndex: 0,
                                                             ino: "ino-\(id)", localRelativePath: "p-\(id)",
                                                             receivedBytes: 10, totalBytes: 10, state: "downloaded"))
        }

        try store.deleteItem(connectionID: "C1", itemID: "i1")

        // i1: parent + file rows gone.
        #expect(try store.download(connectionID: "C1", itemID: "i1") == nil)
        // i2: untouched.
        #expect(try store.download(connectionID: "C1", itemID: "i2")?.download.state == "downloaded")
        #expect(try store.totalDownloadedBytes(connectionID: "C1") == 10)
    }

    /// Builds a genuine v1+v2+v3-ONLY database file (registers "v1", "v2", "v3", replicating the
    /// frozen migrations byte-for-byte — same discipline as `seedV1OnlyDatabase`/
    /// `seedV1V2OnlyDatabase`, one migration further) with real `cachedItem`/`cachedItemDetail`/
    /// `cachedItemPref` rows, then closes it. Reopening through the production
    /// `LibraryCacheStore` runs v1+v2+v3+v4, so v4's two `CREATE TABLE`s (additive — no `ALTER`)
    /// are proven against a genuinely pre-existing v1+v2+v3 file rather than a fresh already-v4
    /// store.
    private func seedV1V2V3OnlyDatabase(at url: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "cachedConnection") { t in
                t.primaryKey("id", .text)
                t.column("address", .text).notNull()
                t.column("name", .text).notNull()
                t.column("username", .text).notNull()
                t.column("authMethod", .text).notNull()
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(table: "cachedLibrary") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("displayOrder", .integer).notNull()
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedItem") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("libraryID", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("authorName", .text)
                t.column("duration", .double)
                t.column("updatedAt", .integer)
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedProgress") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")
                t.column("currentTime", .double).notNull()
                t.column("isFinished", .boolean).notNull()
                t.column("lastUpdate", .integer).notNull()
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
            try db.create(virtualTable: "itemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "cachedItem")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("authorName")
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "cachedItem") { t in
                t.add(column: "subtitle", .text)
                t.add(column: "narratorName", .text)
                t.add(column: "seriesName", .text)
                t.add(column: "genresJSON", .text)
                t.add(column: "publishedYear", .text)
                t.add(column: "descriptionSnippet", .text)
            }
            try db.create(table: "cachedItemDetail") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("description", .text)
                t.column("publisher", .text)
                t.column("isbn", .text)
                t.column("asin", .text)
                t.column("language", .text)
                t.column("explicit", .boolean)
                t.column("abridged", .boolean)
                t.column("publishedDate", .text)
                t.column("chaptersJSON", .text)
                t.primaryKey(["connectionID", "itemID"])
            }
            try db.create(table: "cachedEpisode") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull()
                t.column("idx", .integer)
                t.column("season", .text)
                t.column("episode", .text)
                t.column("episodeType", .text)
                t.column("title", .text)
                t.column("subtitle", .text)
                t.column("episodeDescription", .text)
                t.column("pubDate", .text)
                t.column("publishedAt", .integer)
                t.column("durationSeconds", .double)
                t.column("sizeBytes", .integer)
                t.column("guid", .text)
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
        }
        migrator.registerMigration("v3") { db in
            try db.create(table: "cachedItemPref") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("playbackRate", .double)
                t.primaryKey(["connectionID", "itemID"])
            }
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cachedItem (id, connectionID, libraryID, title, authorName, duration, updatedAt,
                                         subtitle, narratorName, seriesName, genresJSON, publishedYear, descriptionSnippet)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["i1", "C1", "L1", "Dracula", "Bram Stoker", 100.0, 1,
                            "A Novel", "Narrator Name", "Gothic Classics", "[\"Horror\"]", "1897", "A count..."])
            try db.execute(sql: """
                INSERT INTO cachedItemDetail (connectionID, itemID, description, publisher)
                VALUES (?, ?, ?, ?)
                """,
                arguments: ["C1", "i1", "Full description", "Acme Pub"])
            try db.execute(sql: """
                INSERT INTO cachedItemPref (connectionID, itemID, playbackRate)
                VALUES (?, ?, ?)
                """,
                arguments: ["C1", "i1", 1.5])
        }
        try dbQueue.close()   // release the file so the real store can reopen it
    }

    /// THE sabotage-provable v4 migration test (same rigor as `v2AddsDetailColumnsPreservingV1Rows`
    /// and `v3AddsPrefTablePreservingV1V2Rows`): seed a genuine v1+v2+v3-only file, reopen through
    /// the production store (runs v1+v2+v3+v4 — v4's two `CREATE TABLE`s executed against real
    /// pre-existing tables), and assert (1) the v1 row + its v2 columns survive untouched, (2) the
    /// v2 `cachedItemDetail` row survives, (3) the v3 `cachedItemPref` row survives, and (4) the
    /// new `cachedDownload`/`cachedDownloadFile` tables exist, are queryable, and round-trip a
    /// real download.
    @Test func v4AddsDownloadTablesPreservingV1V2V3Rows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appending(path: "cache.sqlite")

        try seedV1V2V3OnlyDatabase(at: dbURL)                   // genuine v1+v2+v3-only file on disk
        let store = try LibraryCacheStore(databaseURL: dbURL)   // reopen → runs v1+v2+v3+v4 (CREATE TABLE only)

        // The pre-existing v1 row + its v2 columns survive, values intact.
        let fetched = try store.items(connectionID: "C1", libraryID: "L1").first
        #expect(fetched?.id == "i1")
        #expect(fetched?.title == "Dracula")
        #expect(fetched?.authorName == "Bram Stoker")
        #expect(fetched?.subtitle == "A Novel")
        #expect(fetched?.genres == ["Horror"])
        // The pre-existing v2 detail row survives.
        #expect(try store.itemDetail(connectionID: "C1", itemID: "i1")?.publisher == "Acme Pub")
        // The pre-existing v3 pref row survives.
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == 1.5)

        // The new v4 tables exist, are queryable (a missing table would throw), and round-trip a
        // real download + its per-file breakdown.
        #expect(try store.download(connectionID: "C1", itemID: "i1") == nil)
        try store.upsertDownload(CachedDownload(connectionID: "C1", itemID: "i1", state: "downloading",
                                                receivedBytes: 10, totalBytes: 100, updatedAt: 5))
        try store.upsertDownloadFile(CachedDownloadFile(connectionID: "C1", itemID: "i1", trackIndex: 0,
                                                         ino: "ino1", localRelativePath: "C1/i1/track-0.m4b",
                                                         receivedBytes: 10, totalBytes: 100, state: "downloading"))
        let download = try #require(try store.download(connectionID: "C1", itemID: "i1"))
        #expect(download.download.state == "downloading")
        #expect(download.files.map(\.localRelativePath) == ["C1/i1/track-0.m4b"])
        #expect(try store.totalDownloadedBytes(connectionID: "C1") == 10)
    }

    // MARK: - v5: persisted offline local sessions (Task 6)

    private func makeLocalSession(
        id: String, connectionID: String = "C1", itemID: String = "i1", episodeID: String? = nil,
        timeListening: Double, currentTime: Double = 0, duration: Double = 100,
        startedAt: Int = 1, updatedAt: Int = 1
    ) -> CachedLocalSession {
        CachedLocalSession(
            id: id, connectionID: connectionID, itemID: itemID, episodeID: episodeID,
            mediaType: (episodeID ?? "").isEmpty ? "book" : "podcast",
            currentTime: currentTime, timeListening: timeListening, duration: duration,
            startedAt: startedAt, updatedAt: updatedAt,
            deviceId: "dev1", clientName: "Colophon", clientVersion: "1.0", manufacturer: "Apple", model: "iPhone")
    }

    @Test func localSessionRoundTripByUUID() throws {
        let store = try makeStore()
        try store.upsertLocalSession(makeLocalSession(id: "s1", timeListening: 42, currentTime: 63.5))
        let fetched = try #require(try store.localSession(id: "s1"))
        #expect(fetched.itemID == "i1")
        #expect(fetched.timeListening == 42)
        #expect(fetched.currentTime == 63.5)
        #expect(fetched.mediaType == "book")
        #expect(fetched.deviceId == "dev1")
        #expect(try store.localSession(id: "missing") == nil)
    }

    /// The store's `upsertLocalSession` is a full-row upsert keyed by UUID: a re-upsert of the SAME
    /// id OVERWRITES that row (the CALLER owns accumulating `timeListening` before upserting), while
    /// a DIFFERENT id is a distinct row — so two offline sessions for the same item coexist.
    @Test func localSessionUpsertOverwritesSameUUIDButKeepsDistinctUUIDs() throws {
        let store = try makeStore()
        try store.upsertLocalSession(makeLocalSession(id: "s1", timeListening: 10))
        try store.upsertLocalSession(makeLocalSession(id: "s1", timeListening: 25))   // caller-accumulated total
        try store.upsertLocalSession(makeLocalSession(id: "s2", itemID: "i1", timeListening: 7))   // new session, same item

        #expect(try store.localSession(id: "s1")?.timeListening == 25)   // overwritten, not doubled
        #expect(try store.localSession(id: "s2")?.timeListening == 7)
        #expect(try store.localSessions(connectionID: "C1").count == 2)  // two rows for the same item
    }

    @Test func localSessionsListScopedToConnectionOldestStartedFirst() throws {
        let store = try makeStore()
        try store.upsertLocalSession(makeLocalSession(id: "s2", timeListening: 5, startedAt: 200))
        try store.upsertLocalSession(makeLocalSession(id: "s1", timeListening: 5, startedAt: 100))
        try store.upsertLocalSession(makeLocalSession(id: "s9", connectionID: "C2", timeListening: 5, startedAt: 50))

        #expect(try store.localSessions(connectionID: "C1").map(\.id) == ["s1", "s2"])   // oldest startedAt first
        #expect(try store.localSessions(connectionID: "C2").map(\.id) == ["s9"])          // scoped
    }

    @Test func deleteLocalSessionRemovesOnlyThatSession() throws {
        let store = try makeStore()
        try store.upsertLocalSession(makeLocalSession(id: "s1", timeListening: 5))
        try store.upsertLocalSession(makeLocalSession(id: "s2", timeListening: 5))
        try store.deleteLocalSession(id: "s1")
        #expect(try store.localSession(id: "s1") == nil)
        #expect(try store.localSession(id: "s2") != nil)
    }

    @Test func deleteConnectionCascadesToLocalSessions() throws {
        let store = try makeStore()
        try store.upsertLocalSession(makeLocalSession(id: "s1", connectionID: "C1", timeListening: 5))
        try store.upsertLocalSession(makeLocalSession(id: "s9", connectionID: "C2", timeListening: 5))
        try store.deleteConnection(connectionID: "C1")
        #expect(try store.localSessions(connectionID: "C1").isEmpty)
        #expect(try store.localSessions(connectionID: "C2").count == 1)   // scoped: untouched
    }

    /// Builds a genuine v1..v4-ONLY database file (replicating the frozen migrations byte-for-byte,
    /// one migration further than `seedV1V2V3OnlyDatabase`), seeds real rows in each, then closes it —
    /// so reopening through the production store runs v1..v4+v5 and v5's single additive `CREATE TABLE`
    /// is proven against a genuinely pre-existing v1..v4 file, not a fresh already-v5 store.
    private func seedV1V2V3V4OnlyDatabase(at url: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "cachedConnection") { t in
                t.primaryKey("id", .text)
                t.column("address", .text).notNull()
                t.column("name", .text).notNull()
                t.column("username", .text).notNull()
                t.column("authMethod", .text).notNull()
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(table: "cachedLibrary") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("displayOrder", .integer).notNull()
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedItem") { t in
                t.column("id", .text).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("libraryID", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("authorName", .text)
                t.column("duration", .double)
                t.column("updatedAt", .integer)
                t.primaryKey(["connectionID", "id"])
            }
            try db.create(table: "cachedProgress") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")
                t.column("currentTime", .double).notNull()
                t.column("isFinished", .boolean).notNull()
                t.column("lastUpdate", .integer).notNull()
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
            try db.create(virtualTable: "itemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "cachedItem")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("authorName")
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "cachedItem") { t in
                t.add(column: "subtitle", .text)
                t.add(column: "narratorName", .text)
                t.add(column: "seriesName", .text)
                t.add(column: "genresJSON", .text)
                t.add(column: "publishedYear", .text)
                t.add(column: "descriptionSnippet", .text)
            }
            try db.create(table: "cachedItemDetail") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("description", .text)
                t.column("publisher", .text)
                t.column("isbn", .text)
                t.column("asin", .text)
                t.column("language", .text)
                t.column("explicit", .boolean)
                t.column("abridged", .boolean)
                t.column("publishedDate", .text)
                t.column("chaptersJSON", .text)
                t.primaryKey(["connectionID", "itemID"])
            }
            try db.create(table: "cachedEpisode") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull()
                t.column("idx", .integer)
                t.column("season", .text)
                t.column("episode", .text)
                t.column("episodeType", .text)
                t.column("title", .text)
                t.column("subtitle", .text)
                t.column("episodeDescription", .text)
                t.column("pubDate", .text)
                t.column("publishedAt", .integer)
                t.column("durationSeconds", .double)
                t.column("sizeBytes", .integer)
                t.column("guid", .text)
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
        }
        migrator.registerMigration("v3") { db in
            try db.create(table: "cachedItemPref") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("playbackRate", .double)
                t.primaryKey(["connectionID", "itemID"])
            }
        }
        migrator.registerMigration("v4") { db in
            try db.create(table: "cachedDownload") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")
                t.column("state", .text).notNull()
                t.column("receivedBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .integer).notNull()
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
            try db.create(table: "cachedDownloadFile") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")
                t.column("trackIndex", .integer).notNull()
                t.column("ino", .text).notNull()
                t.column("localRelativePath", .text).notNull()
                t.column("receivedBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer).notNull().defaults(to: 0)
                t.column("state", .text).notNull()
                t.column("mimeType", .text)
                t.column("durationSeconds", .double)
                t.primaryKey(["connectionID", "itemID", "episodeID", "trackIndex"])
            }
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cachedItem (id, connectionID, libraryID, title, authorName, duration, updatedAt,
                                         subtitle, narratorName, seriesName, genresJSON, publishedYear, descriptionSnippet)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["i1", "C1", "L1", "Dracula", "Bram Stoker", 100.0, 1,
                            "A Novel", "Narrator Name", "Gothic Classics", "[\"Horror\"]", "1897", "A count..."])
            try db.execute(sql: "INSERT INTO cachedItemPref (connectionID, itemID, playbackRate) VALUES (?, ?, ?)",
                           arguments: ["C1", "i1", 1.5])
            try db.execute(sql: """
                INSERT INTO cachedDownload (connectionID, itemID, episodeID, state, receivedBytes, totalBytes, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["C1", "i1", "", "downloaded", 100, 100, 5])
        }
        try dbQueue.close()
    }

    /// THE sabotage-provable v5 migration test (same rigor as the v2/v3/v4 ones): seed a genuine
    /// v1..v4-only file, reopen through the production store (runs v1..v4+v5 — v5's single additive
    /// `CREATE TABLE` executed against real pre-existing tables), and assert the v1 row + its v2
    /// columns, the v3 pref row, and the v4 download row all survive untouched, then that the new
    /// `cachedLocalSession` table exists, is queryable, and round-trips a real offline session.
    @Test func v5AddsLocalSessionTablePreservingV1V2V3V4Rows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appending(path: "cache.sqlite")

        try seedV1V2V3V4OnlyDatabase(at: dbURL)                 // genuine v1..v4-only file on disk
        let store = try LibraryCacheStore(databaseURL: dbURL)   // reopen → runs v1..v4+v5 (CREATE TABLE only)

        // Pre-existing rows across every earlier migration survive, values intact.
        #expect(try store.items(connectionID: "C1", libraryID: "L1").first?.title == "Dracula")
        #expect(try store.items(connectionID: "C1", libraryID: "L1").first?.genres == ["Horror"])
        #expect(try store.playbackRate(connectionID: "C1", itemID: "i1") == 1.5)
        #expect(try store.download(connectionID: "C1", itemID: "i1")?.download.state == "downloaded")

        // The new v5 table exists, is queryable (a missing table would throw), and round-trips.
        #expect(try store.localSessions(connectionID: "C1").isEmpty)
        try store.upsertLocalSession(makeLocalSession(id: "s1", timeListening: 30, currentTime: 55))
        #expect(try store.localSession(id: "s1")?.timeListening == 30)
        #expect(try store.localSessions(connectionID: "C1").map(\.id) == ["s1"])
    }
}
