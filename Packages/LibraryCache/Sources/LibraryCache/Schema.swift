import GRDB

enum Schema {
    // SCHEMA FREEZE (as of M1b): v1 below is FROZEN. Real databases now exist post-M1b —
    // connections, tokens, and cached library/progress state are established on real devices —
    // so v1 may NEVER be edited again. Any future schema change is a NEW "v2" (or later)
    // `registerMigration` step appended after this one; GRDB then migrates existing v1
    // databases forward in place instead of discarding them.
    //
    // The `#if DEBUG migrator.eraseDatabaseOnSchemaChange = true #endif` flag that used to sit
    // here (GRDB's sanctioned pre-freeze dev convenience: edit v1, wipe and recreate) has been
    // REMOVED, not merely left as a comment. With v1 frozen, the only way that flag could still
    // fire is a stray future edit to this migration's body — and firing would silently wipe a
    // real dev's local cache/connections. Removing the flag turns that mistake into a loud
    // migration-mismatch failure instead of silent data loss. This is safe for existing
    // pre-freeze dev databases: the flag never changed what v1 produces, only what happened on
    // a MISMATCH, so a dev with an already-migrated v1 database is unaffected — GRDB sees the
    // same schema and does nothing.
    static var migrator: DatabaseMigrator {
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
        return migrator
    }
}
