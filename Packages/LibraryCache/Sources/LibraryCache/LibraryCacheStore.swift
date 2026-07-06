import Foundation
import GRDB

public struct LibraryCacheStore: Sendable {
    private let pool: DatabasePool

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        pool = try DatabasePool(path: databaseURL.path)
        try Schema.migrator.migrate(pool)
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
