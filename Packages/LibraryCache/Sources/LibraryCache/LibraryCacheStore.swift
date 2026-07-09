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

    /// Removes a connection and every row scoped to it — the `cachedConnection` row plus its
    /// `cachedLibrary`, `cachedItem` (and, via the FTS5 `synchronize` trigger, its search-index
    /// rows), `cachedItemDetail`, `cachedEpisode`, `cachedProgress`, `cachedDownload`,
    /// `cachedDownloadFile`, and `cachedLocalSession` rows — in ONE transaction. Used by
    /// `AppState.removeConnection` so a "forget this server" leaves no orphaned cache (including no
    /// orphaned downloaded files' bookkeeping and no orphaned pending offline sessions) behind — the
    /// only place a pending offline session is dropped, a deliberate user-driven purge, not a silent
    /// loss. Other connections are untouched.
    public func deleteConnection(connectionID: String) throws {
        try pool.write { db in
            _ = try CachedItem.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedItemDetail.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedEpisode.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedProgress.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedDownload.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedDownloadFile.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedLocalSession.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedLibrary.filter(Column("connectionID") == connectionID).deleteAll(db)
            _ = try CachedConnection.filter(Column("id") == connectionID).deleteAll(db)
        }
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

    /// Removes a single item (and, via the FTS5 `synchronize` trigger, its search index row),
    /// plus its `cachedItemDetail`, `cachedEpisode`, `cachedDownload`, and `cachedDownloadFile`
    /// rows — all in ONE transaction so no orphaned detail/episode/download cache survives the
    /// item.
    public func deleteItem(connectionID: String, itemID: String) throws {
        try pool.write { db in
            _ = try CachedItem.filter(Column("connectionID") == connectionID
                                       && Column("id") == itemID).deleteAll(db)
            _ = try CachedItemDetail.filter(Column("connectionID") == connectionID
                                             && Column("itemID") == itemID).deleteAll(db)
            _ = try CachedEpisode.filter(Column("connectionID") == connectionID
                                          && Column("itemID") == itemID).deleteAll(db)
            _ = try CachedDownload.filter(Column("connectionID") == connectionID
                                           && Column("itemID") == itemID).deleteAll(db)
            _ = try CachedDownloadFile.filter(Column("connectionID") == connectionID
                                               && Column("itemID") == itemID).deleteAll(db)
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

    /// One browse-row item by its `(connectionID, id)` primary key, or nil if the item was never
    /// cached. Offline playback (M2a Task 5) reads it for the now-playing title/author of a
    /// downloaded book (the pinned `CachedItemDetail` carries chapters/description but not the
    /// title/author, which live on this row).
    public func item(connectionID: String, itemID: String) throws -> CachedItem? {
        try pool.read {
            try CachedItem.fetchOne($0, key: ["connectionID": connectionID, "id": itemID])
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

    /// Observes ALL progress rows for a connection as a live stream. The home shelves subscribe so
    /// their per-item progress pills update the instant a socket `progressUpdated`/`progressBatch`
    /// event — or the `me()` join — upserts `cachedProgress`, with no shelf refetch. Connection-
    /// scoped (not per-item) because a shelf spans arbitrarily many items; the view indexes the
    /// result by `itemID` client-side.
    public func observeProgress(connectionID: String) -> AsyncValueObservation<[CachedProgress]> {
        ValueObservation.tracking { db in
            try CachedProgress.filter(Column("connectionID") == connectionID).fetchAll(db)
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

    // MARK: - v2: item detail + podcast episodes

    /// Upserts the 1:1 heavy detail row for an item (on-demand, from `?expanded=1`).
    public func upsertItemDetail(_ detail: CachedItemDetail) throws {
        try pool.write { try detail.upsert($0) }
    }

    public func itemDetail(connectionID: String, itemID: String) throws -> CachedItemDetail? {
        try pool.read {
            try CachedItemDetail.fetchOne($0, key: ["connectionID": connectionID, "itemID": itemID])
        }
    }

    /// Reconciles one item's full episode list against the cache, scoped to `(connectionID,
    /// itemID)`: deletes that item's episodes absent from `episodes`, then upserts the rest — in
    /// ONE transaction, the same replace-semantics `replaceItems` uses for library items. Other
    /// items' episodes are untouched.
    public func upsertEpisodes(_ episodes: [CachedEpisode], connectionID: String, itemID: String) throws {
        try pool.write { db in
            let ids = episodes.map(\.episodeID)
            try CachedEpisode.filter(Column("connectionID") == connectionID
                                      && Column("itemID") == itemID
                                      && !ids.contains(Column("episodeID"))).deleteAll(db)
            for episode in episodes {
                var episode = episode
                episode.connectionID = connectionID
                episode.itemID = itemID
                try episode.upsert(db)
            }
        }
    }

    /// Episodes for one item, newest first. NULL `publishedAt` sorts LAST here (SQLite's default
    /// for `ORDER BY … DESC` places NULLs at the end), so episodes missing a publish date fall
    /// below dated ones rather than jumping to the top.
    public func episodes(connectionID: String, itemID: String) throws -> [CachedEpisode] {
        try pool.read {
            try CachedEpisode.filter(Column("connectionID") == connectionID && Column("itemID") == itemID)
                .order(Column("publishedAt").desc)
                .fetchAll($0)
        }
    }

    /// Live stream of one item's episodes (M1c-c), same ordering as `episodes(connectionID:itemID:)`
    /// — mirrors `observeItems`'s role for the browse grid: the podcast-detail view subscribes so
    /// an `upsertEpisodes` reconcile (fresh `podcastItem` fetch) repaints instantly with no refetch.
    public func observeEpisodes(connectionID: String, itemID: String) -> AsyncValueObservation<[CachedEpisode]> {
        ValueObservation.tracking { db in
            try CachedEpisode.filter(Column("connectionID") == connectionID && Column("itemID") == itemID)
                .order(Column("publishedAt").desc)
                .fetchAll(db)
        }.values(in: pool)
    }

    // MARK: - v3: per-book playback-rate preference

    /// Sets (or, with `rate: nil`, clears back to "no per-book rate") this book's persisted
    /// playback rate. Currently a full-row upsert, which is safe ONLY because `playbackRate` is the
    /// sole non-key column. ⚠️ When a sibling per-book pref is added to `cachedItemPref`, this MUST
    /// become a read-modify-write (or a single-column update), or it will NULL that sibling column
    /// on every rate change.
    public func setPlaybackRate(_ rate: Double?, connectionID: String, itemID: String) throws {
        try pool.write { db in
            try CachedItemPref(connectionID: connectionID, itemID: itemID, playbackRate: rate).upsert(db)
        }
    }

    /// This book's persisted playback rate, or nil when none is stored (no row, or a row whose
    /// `playbackRate` was cleared) — the caller falls back to the global default rate setting.
    public func playbackRate(connectionID: String, itemID: String) throws -> Double? {
        try pool.read { db in
            try CachedItemPref.fetchOne(db, key: ["connectionID": connectionID, "itemID": itemID])?.playbackRate
        }
    }

    // MARK: - v4: download records

    /// Upserts a download's AGGREGATE (parent) row — e.g. a state transition (`queued` →
    /// `downloading` → `downloaded`/`failed`) or an aggregate byte-count tick. Does not touch
    /// this download's per-file rows; see `upsertDownloadFile` for those.
    public func upsertDownload(_ download: CachedDownload) throws {
        try pool.write { try download.upsert($0) }
    }

    /// Upserts one file's row within a download's per-file breakdown — e.g. a single file's
    /// progress tick or terminal state. Does not touch the parent `cachedDownload` row or any
    /// sibling file; the caller (`DownloadCoordinator`, Task 4) keeps the parent's aggregate
    /// state/bytes in sync separately via `upsertDownload`.
    public func upsertDownloadFile(_ file: CachedDownloadFile) throws {
        try pool.write { try file.upsert($0) }
    }

    /// One download's parent row plus its full per-file breakdown (ordered by `trackIndex`), or
    /// nil if no download exists at this key.
    public func download(
        connectionID: String, itemID: String, episodeID: String? = nil
    ) throws -> CachedDownloadWithFiles? {
        try pool.read { db in
            let episodeID = episodeID ?? ""
            guard let parent = try CachedDownload.fetchOne(db, key: [
                "connectionID": connectionID, "itemID": itemID, "episodeID": episodeID,
            ]) else { return nil }
            let files = try CachedDownloadFile
                .filter(Column("connectionID") == connectionID
                        && Column("itemID") == itemID
                        && Column("episodeID") == episodeID)
                .order(Column("trackIndex"))
                .fetchAll(db)
            return CachedDownloadWithFiles(download: parent, files: files)
        }
    }

    /// Every download's parent row for a connection (books + podcast episodes), newest-updated
    /// first — the Downloads tab's listing. Parent rows only; call
    /// `download(connectionID:itemID:episodeID:)` for one download's file breakdown.
    public func downloads(connectionID: String) throws -> [CachedDownload] {
        try pool.read {
            try CachedDownload.filter(Column("connectionID") == connectionID)
                .order(Column("updatedAt").desc)
                .fetchAll($0)
        }
    }

    /// Live stream of a connection's downloads — mirrors `observeItems`'/`observeEpisodes`'s role
    /// for the Downloads tab: an `upsertDownload` (a progress tick or state transition) repaints
    /// instantly with no refetch needed by the observer.
    public func observeDownloads(connectionID: String) -> AsyncValueObservation<[CachedDownload]> {
        ValueObservation.tracking { db in
            try CachedDownload.filter(Column("connectionID") == connectionID)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }.values(in: pool)
    }

    /// Removes a download's parent row plus its full per-file breakdown in ONE transaction — no
    /// orphaned `cachedDownloadFile` rows survive a delete.
    public func deleteDownload(connectionID: String, itemID: String, episodeID: String? = nil) throws {
        try pool.write { db in
            let episodeID = episodeID ?? ""
            _ = try CachedDownload.filter(Column("connectionID") == connectionID
                                           && Column("itemID") == itemID
                                           && Column("episodeID") == episodeID).deleteAll(db)
            _ = try CachedDownloadFile.filter(Column("connectionID") == connectionID
                                               && Column("itemID") == itemID
                                               && Column("episodeID") == episodeID).deleteAll(db)
        }
    }

    /// Sum of `receivedBytes` across every FILE row (`cachedDownloadFile`) for a connection — the
    /// Downloads tab's total-storage figure. Sums the file rows (the actual on-disk bytes)
    /// rather than the parent `cachedDownload` rows' aggregate counters, so storage is accurate
    /// even if a caller's aggregate bookkeeping ever lags.
    public func totalDownloadedBytes(connectionID: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(receivedBytes), 0) FROM cachedDownloadFile WHERE connectionID = ?",
                arguments: [connectionID]
            ) ?? 0
        }
    }

    // MARK: - v5: persisted offline local sessions (Task 6)

    /// Upserts one offline `cachedLocalSession` row by its client-generated UUID (`id`). Used both
    /// to INSERT a fresh session (first accrual tick of a new offline playback) and to UPDATE the
    /// current session (subsequent ticks bump `currentTime`/`timeListening`/`updatedAt`). The caller
    /// owns the ACCUMULATION of `timeListening` (read-modify-write of the row's running total) — this
    /// is a plain full-row upsert, so a caller MUST pass the already-accumulated total, not a delta.
    public func upsertLocalSession(_ session: CachedLocalSession) throws {
        try pool.write { try session.upsert($0) }
    }

    /// One offline session by its UUID, or nil — the read half of the accrual read-modify-write, and
    /// the reconcile's re-read to detect a tick that landed mid-reconcile (an advanced `updatedAt`).
    public func localSession(id: String) throws -> CachedLocalSession? {
        try pool.read { try CachedLocalSession.fetchOne($0, key: id) }
    }

    /// Every pending offline session for a connection, oldest-started first — the reconcile's input
    /// set (each becomes a `LocalPlaybackSession` posted to `POST /api/session/local-all`). Ordered
    /// by `startedAt` so a stable, chronological batch is posted.
    public func localSessions(connectionID: String) throws -> [CachedLocalSession] {
        try pool.read {
            try CachedLocalSession.filter(Column("connectionID") == connectionID)
                .order(Column("startedAt"))
                .fetchAll($0)
        }
    }

    /// Prunes ONE offline session by its UUID — called after the server accepts it
    /// (`LocalSessionSyncResult.success == true`). A rejected/failed session is deliberately NOT
    /// pruned (its offline listen time is never silently dropped — Task 3/6 contract).
    public func deleteLocalSession(id: String) throws {
        try pool.write { _ = try CachedLocalSession.filter(key: id).deleteAll($0) }
    }
}
