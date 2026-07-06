import GRDB

enum Schema {
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
                t.primaryKey("id", .text)
                t.column("connectionID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("displayOrder", .integer).notNull()
            }
            try db.create(table: "cachedItem") { t in
                t.primaryKey("id", .text)
                t.column("connectionID", .text).notNull().indexed()
                t.column("libraryID", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("authorName", .text)
                t.column("duration", .double)
                t.column("updatedAt", .integer)
            }
            try db.create(table: "cachedProgress") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text)
                t.column("currentTime", .double).notNull()
                t.column("isFinished", .boolean).notNull()
                t.column("lastUpdate", .integer).notNull()
                t.primaryKey(["connectionID", "itemID"])
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
