import Foundation
import GRDB

public struct LibraryCacheStore: Sendable {
    private let pool: DatabasePool

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            pool = try Self.openAndMigrate(at: databaseURL)
        } catch {
            // Corrupt or incompatible store: the cache is reconstructable from the server — recreate.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
            pool = try Self.openAndMigrate(at: databaseURL)
        }
    }

    private static func openAndMigrate(at url: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path)
        try Schema.migrator.migrate(pool)
        return pool
    }

    public func upsertConnection(_ c: CachedConnection) throws {
        try pool.write { try c.upsert($0) }
    }

    public func connections() throws -> [CachedConnection] {
        try pool.read { try CachedConnection.order(Column("sortIndex")).fetchAll($0) }
    }

    public func upsertLibraries(_ libs: [CachedLibrary], connectionID: String) throws {
        try pool.write { db in
            try CachedLibrary.filter(Column("connectionID") == connectionID
                                     && !libs.map(\.id).contains(Column("id"))).deleteAll(db)
            for lib in libs { try lib.upsert(db) }
        }
    }

    public func upsertItemsPage(_ items: [CachedItem], connectionID: String, libraryID: String) throws {
        try pool.write { db in
            for item in items {
                var item = item
                item.connectionID = connectionID
                item.libraryID = libraryID
                try item.upsert(db)
            }
        }
    }

    public func upsertProgress(_ p: CachedProgress) throws {
        try pool.write { db in
            if let existing = try CachedProgress.fetchOne(db, key: ["connectionID": p.connectionID,
                                                                    "itemID": p.itemID,
                                                                    "episodeID": p.episodeID]),
               existing.lastUpdate > p.lastUpdate { return }   // last-write-wins by server timestamp
            try p.upsert(db)
        }
    }

    /// Batched progress sync: skips rows that are stale OR unchanged (`>=`, stronger than the
    /// single-row `>` above) so a re-sync of already-current progress never churns observers.
    public func upsertProgressBatch(_ batch: [CachedProgress]) throws {
        try pool.write { db in
            for p in batch {
                if let existing = try CachedProgress.fetchOne(db, key: ["connectionID": p.connectionID,
                                                                        "itemID": p.itemID,
                                                                        "episodeID": p.episodeID]),
                   existing.lastUpdate >= p.lastUpdate { continue }
                try p.upsert(db)
            }
        }
    }

    /// Removes a single item (and, via the FTS5 `synchronize` trigger, its search index row).
    public func deleteItem(connectionID: String, itemID: String) throws {
        try pool.write { db in
            _ = try CachedItem.filter(Column("connectionID") == connectionID
                                       && Column("id") == itemID).deleteAll(db)
        }
    }

    /// Reconciles a library page's full item list against the cache: deletes rows scoped to
    /// (connectionID, libraryID) that are absent from `items`, then upserts the rest. Progress
    /// rows are untouched — the server owns their lifecycle independently of item paging.
    public func replaceItems(_ items: [CachedItem], connectionID: String, libraryID: String) throws {
        try pool.write { db in
            let ids = items.map(\.id)
            try CachedItem.filter(Column("connectionID") == connectionID
                                   && Column("libraryID") == libraryID
                                   && !ids.contains(Column("id"))).deleteAll(db)
            for item in items {
                var item = item
                item.connectionID = connectionID
                item.libraryID = libraryID
                try item.upsert(db)
            }
        }
    }

    public func items(connectionID: String, libraryID: String) throws -> [CachedItem] {
        try pool.read {
            try CachedItem.filter(Column("connectionID") == connectionID && Column("libraryID") == libraryID)
                .order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll($0)
        }
    }

    public func progress(connectionID: String, itemID: String, episodeID: String? = nil) throws -> CachedProgress? {
        try pool.read {
            try CachedProgress.fetchOne($0, key: ["connectionID": connectionID,
                                                  "itemID": itemID,
                                                  "episodeID": episodeID ?? ""])
        }
    }

    public func observeLibraries(connectionID: String) -> AsyncValueObservation<[CachedLibrary]> {
        ValueObservation.tracking { db in
            try CachedLibrary.filter(Column("connectionID") == connectionID)
                .order(Column("displayOrder")).fetchAll(db)
        }.values(in: pool)
    }

    public func observeItems(connectionID: String, libraryID: String) -> AsyncValueObservation<[CachedItem]> {
        ValueObservation.tracking { db in
            try CachedItem.filter(Column("connectionID") == connectionID && Column("libraryID") == libraryID)
                .order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }.values(in: pool)
    }

    public func searchItems(connectionID: String, query: String) throws -> [CachedItem] {
        try pool.read { db in
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
            let sql = """
                SELECT cachedItem.* FROM cachedItem
                JOIN itemFTS ON itemFTS.rowid = cachedItem.rowid AND itemFTS MATCH ?
                WHERE cachedItem.connectionID = ?
                ORDER BY itemFTS.rank
                """
            return try CachedItem.fetchAll(db, sql: sql, arguments: [pattern, connectionID])
        }
    }
}
