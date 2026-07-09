import GRDB

enum Schema {
    // SCHEMA FREEZE (as of M1b): v1 below is FROZEN. Production databases now exist —
    // connections, tokens, and cached library/progress state are established on real devices —
    // so v1's body may NEVER be edited again. Any future schema change is a NEW "v2" (or later)
    // `registerMigration` step appended after v1; GRDB then migrates existing v1 databases
    // forward in place instead of discarding them.
    //
    // Why `eraseDatabaseOnSchemaChange` stays, and why it's DEBUG-only:
    //
    // - Production ships WITHOUT it (compiled out below), so production user data is never at
    //   risk from this flag. And even if it were on, a legitimate future v1→v2 migration updates
    //   the migrator's expected schema in lockstep, so properly-migrated databases would still
    //   match and never be wiped — the flag only fires on a schema-shape MISMATCH.
    // - DEBUG keeps it precisely because GRDB does NOT diff schema shape without it: the plain
    //   migrator only checks the `grdb_migrations` bookkeeping table for the NAME "v1". A dev
    //   whose local cache DB recorded "v1" under an OLDER v1 shape (v1 was amended during
    //   M1a/M1b development, e.g. the composite-PK change) would open with no error and then hit
    //   a latent `no such column`-style crash at query time — which the store's init recovery
    //   does NOT catch (it only reacts to open/migrate-time throws). With the flag, that stale
    //   dev DB is detected by shape comparison and cleanly recreated on next launch; the cache
    //   is reconstructable from the server, so a DEBUG wipe costs nothing.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
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
                t.column("episodeID", .text).notNull().defaults(to: "")   // "" = book/no episode
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
        // v2 (M1c-a): ALTER-only + CREATE. Never edit v1's body above — a v1 database (existing
        // connections/tokens/progress on real devices) migrates forward in place: new columns are
        // all nullable with no default, so ADD COLUMN back-fills existing rows with NULL and they
        // round-trip unchanged. `cachedItemDetail` and `cachedEpisode` are net-new tables (no data
        // to preserve). `cachedProgress`'s 3-part (connectionID, itemID, episodeID) PK — already
        // correct for per-episode progress — is untouched.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "cachedItem") { t in
                // Browse-facing columns populated from the minified /items list payload; kept
                // lean here so the grid query stays cheap. Full detail lives in cachedItemDetail.
                t.add(column: "subtitle", .text)
                t.add(column: "narratorName", .text)
                t.add(column: "seriesName", .text)
                t.add(column: "genresJSON", .text)          // JSON-encoded [String]
                t.add(column: "publishedYear", .text)
                t.add(column: "descriptionSnippet", .text)  // short/plain, for the grid
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
                t.column("chaptersJSON", .text)   // JSON-encoded [{id,start,end,title}]
                t.primaryKey(["connectionID", "itemID"])
            }
            try db.create(table: "cachedEpisode") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull()
                t.column("idx", .integer)                // avoid reserved word "index"
                t.column("season", .text)
                t.column("episode", .text)
                t.column("episodeType", .text)
                t.column("title", .text)
                t.column("subtitle", .text)
                t.column("episodeDescription", .text)    // avoid clash with "description"
                t.column("pubDate", .text)
                t.column("publishedAt", .integer)
                t.column("durationSeconds", .double)
                t.column("sizeBytes", .integer)
                t.column("guid", .text)
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
        }
        // v3 (M1c-b Task 7): per-book device-local preference — currently just the persisted
        // playback rate, with room for future per-book prefs to join this same row without another
        // migration. ADDITIVE-only, like v2: a brand-new CREATE TABLE, no ALTER against v1/v2's
        // frozen tables, so a v1(+v2) database upgrades in place gaining just this table — no
        // existing row anywhere is touched. `playbackRate` is nullable (absent = "no per-book rate
        // set" — the caller falls back to the global default setting).
        migrator.registerMigration("v3") { db in
            try db.create(table: "cachedItemPref") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("playbackRate", .double)
                t.primaryKey(["connectionID", "itemID"])
            }
        }
        // v4 (M2a Task 2): download records. ALTER/CREATE-only, like v2 and v3 — v1/v2/v3's
        // bodies above are NEVER touched. Two brand-new tables, both additive (no existing data
        // to preserve), so a v1(+v2+v3) database upgrades in place gaining just these tables:
        //
        //   - `cachedDownload`: one row per downloadable unit (a whole book, or a single podcast
        //     episode). PK `(connectionID, itemID, episodeID)` mirrors `cachedProgress`'s 3-part
        //     convention (`episodeID` "" = book-level download, non-empty = one episode). Tracks
        //     the download's AGGREGATE lifecycle (`state`) and byte counts across every file.
        //   - `cachedDownloadFile`: the per-audio-file breakdown for one download (a book can
        //     span several audio files; a podcast episode is normally exactly one). PK adds
        //     `trackIndex` to the parent's key. A CHILD TABLE, not a JSON column on
        //     `cachedDownload` — chosen so a single file's progress tick or failure is a targeted
        //     row upsert/read instead of a full JSON-column decode-mutate-reencode-write, the
        //     same reasoning that put podcast episodes in `cachedEpisode` rather than a JSON
        //     column on `cachedItem`. `localRelativePath` is RELATIVE to a caller-owned downloads
        //     root — never an absolute path, since an absolute path breaks across app-container
        //     moves (e.g. an OS update relocating the sandbox).
        //
        // Pinning: a downloaded item's `cachedItemDetail` (v2) row must already be present so the
        // item stays browsable offline (title/author/chapters/tracks). No new column is added
        // here for that — `cachedItemDetail` is already keyed `(connectionID, itemID)`; the
        // DOWNLOAD ORCHESTRATOR (Task 4) is responsible for fetching+pinning detail before
        // enqueuing a download's files, and for keeping it pinned (never evicted) while any
        // `cachedDownload` row references that item.
        migrator.registerMigration("v4") { db in
            try db.create(table: "cachedDownload") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")   // "" = book/no episode
                t.column("state", .text).notNull()             // queued/downloading/downloaded/failed
                t.column("receivedBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .integer).notNull()
                t.primaryKey(["connectionID", "itemID", "episodeID"])
            }
            try db.create(table: "cachedDownloadFile") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text).notNull().defaults(to: "")   // "" = book/no episode
                t.column("trackIndex", .integer).notNull()
                t.column("ino", .text).notNull()
                t.column("localRelativePath", .text).notNull()   // RELATIVE to the downloads root
                t.column("receivedBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer).notNull().defaults(to: 0)
                t.column("state", .text).notNull()             // queued/downloading/downloaded/failed
                t.column("mimeType", .text)
                t.column("durationSeconds", .double)           // this file's playback seconds (offline timeline)
                t.primaryKey(["connectionID", "itemID", "episodeID", "trackIndex"])
            }
        }
        return migrator
    }
}
