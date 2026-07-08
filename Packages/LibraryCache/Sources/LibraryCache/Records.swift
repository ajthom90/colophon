import Foundation
import GRDB

public struct CachedConnection: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedConnection"

    public var id: String
    public var address: String
    public var name: String
    public var username: String
    public var authMethod: String
    public var sortIndex: Int

    public init(id: String, address: String, name: String, username: String, authMethod: String, sortIndex: Int) {
        self.id = id
        self.address = address
        self.name = name
        self.username = username
        self.authMethod = authMethod
        self.sortIndex = sortIndex
    }
}

public struct CachedLibrary: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedLibrary"

    public var id: String
    public var connectionID: String
    public var name: String
    public var mediaType: String
    public var displayOrder: Int

    public init(id: String, connectionID: String, name: String, mediaType: String, displayOrder: Int) {
        self.id = id
        self.connectionID = connectionID
        self.name = name
        self.mediaType = mediaType
        self.displayOrder = displayOrder
    }
}

public struct CachedItem: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedItem"

    public var id: String
    public var connectionID: String
    public var libraryID: String
    public var title: String
    public var authorName: String?
    public var duration: Double?
    public var updatedAt: Int?
    // v2 (M1c-a): browse-facing detail from the minified /items list payload. All nullable/
    // defaulted so pre-v2 constructor call sites keep compiling and v1 rows migrate with NULLs.
    public var subtitle: String?
    public var narratorName: String?
    public var seriesName: String?
    public var genresJSON: String?   // JSON-encoded [String]; use `genres` below
    public var publishedYear: String?
    public var descriptionSnippet: String?   // short/plain, for the grid — full detail is CachedItemDetail

    public init(
        id: String,
        connectionID: String,
        libraryID: String,
        title: String,
        authorName: String? = nil,
        duration: Double? = nil,
        updatedAt: Int? = nil,
        subtitle: String? = nil,
        narratorName: String? = nil,
        seriesName: String? = nil,
        genres: [String] = [],
        publishedYear: String? = nil,
        descriptionSnippet: String? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.libraryID = libraryID
        self.title = title
        self.authorName = authorName
        self.duration = duration
        self.updatedAt = updatedAt
        self.subtitle = subtitle
        self.narratorName = narratorName
        self.seriesName = seriesName
        self.genresJSON = Self.encodeStrings(genres)
        self.publishedYear = publishedYear
        self.descriptionSnippet = descriptionSnippet
    }

    /// Convenience view over `genresJSON` — the DB stores a JSON string; callers work with `[String]`.
    public var genres: [String] {
        get { Self.decodeStrings(genresJSON) }
        set { genresJSON = Self.encodeStrings(newValue) }
    }

    private static func encodeStrings(_ values: [String]) -> String? {
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeStrings(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }
}

/// 1:1 with a `CachedItem`: heavy on-demand detail (full description, publisher/ISBN/ASIN,
/// language, explicit/abridged flags, chapters) fetched from `GET /api/items/:id?expanded=1` —
/// kept out of `cachedItem` so the browse grid query stays lean.
public struct CachedItemDetail: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedItemDetail"

    public var connectionID: String
    public var itemID: String
    public var description: String?
    public var publisher: String?
    public var isbn: String?
    public var asin: String?
    public var language: String?
    public var explicit: Bool?
    public var abridged: Bool?
    public var publishedDate: String?
    public var chaptersJSON: String?   // JSON-encoded [{id,start,end,title}]; use `chapters` below

    public var id: String { connectionID + "/" + itemID }

    public init(
        connectionID: String,
        itemID: String,
        description: String? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        asin: String? = nil,
        language: String? = nil,
        explicit: Bool? = nil,
        abridged: Bool? = nil,
        publishedDate: String? = nil,
        chapters: [CachedChapter] = []
    ) {
        self.connectionID = connectionID
        self.itemID = itemID
        self.description = description
        self.publisher = publisher
        self.isbn = isbn
        self.asin = asin
        self.language = language
        self.explicit = explicit
        self.abridged = abridged
        self.publishedDate = publishedDate
        self.chaptersJSON = Self.encodeChapters(chapters)
    }

    public var chapters: [CachedChapter] {
        get { Self.decodeChapters(chaptersJSON) }
        set { chaptersJSON = Self.encodeChapters(newValue) }
    }

    private static func encodeChapters(_ chapters: [CachedChapter]) -> String? {
        guard !chapters.isEmpty, let data = try? JSONEncoder().encode(chapters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeChapters(_ json: String?) -> [CachedChapter] {
        guard let json, let data = json.data(using: .utf8),
              let chapters = try? JSONDecoder().decode([CachedChapter].self, from: data) else { return [] }
        return chapters
    }

    enum CodingKeys: String, CodingKey {
        case connectionID, itemID, description, publisher, isbn, asin, language,
             explicit, abridged, publishedDate, chaptersJSON
    }
}

/// A single chapter mark within an item (global seconds, matching `GET /api/items/:id`'s
/// `media.chapters[{id,start,end,title}]`). Mirrors `ABSKit.Chapter`'s shape; LibraryCache does
/// not depend on ABSKit, so this is a deliberate, small duplication rather than a new dependency.
public struct CachedChapter: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var title: String?

    public init(id: Int, start: Double, end: Double, title: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }
}

/// A podcast episode (M1c-c). PK is `(connectionID, itemID, episodeID)`; progress for episodes
/// already lives in `cachedProgress`'s existing 3-part PK — unrelated table, no change there.
public struct CachedEpisode: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedEpisode"

    public var connectionID: String
    public var itemID: String
    public var episodeID: String
    public var idx: Int?
    public var season: String?
    public var episode: String?
    public var episodeType: String?
    public var title: String?
    public var subtitle: String?
    public var episodeDescription: String?
    public var pubDate: String?
    public var publishedAt: Int?
    public var durationSeconds: Double?
    public var sizeBytes: Int?
    public var guid: String?

    public var id: String { connectionID + "/" + itemID + "/" + episodeID }

    public init(
        connectionID: String,
        itemID: String,
        episodeID: String,
        idx: Int? = nil,
        season: String? = nil,
        episode: String? = nil,
        episodeType: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        episodeDescription: String? = nil,
        pubDate: String? = nil,
        publishedAt: Int? = nil,
        durationSeconds: Double? = nil,
        sizeBytes: Int? = nil,
        guid: String? = nil
    ) {
        self.connectionID = connectionID
        self.itemID = itemID
        self.episodeID = episodeID
        self.idx = idx
        self.season = season
        self.episode = episode
        self.episodeType = episodeType
        self.title = title
        self.subtitle = subtitle
        self.episodeDescription = episodeDescription
        self.pubDate = pubDate
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.guid = guid
    }

    enum CodingKeys: String, CodingKey {
        case connectionID, itemID, episodeID, idx, season, episode, episodeType, title, subtitle,
             episodeDescription, pubDate, publishedAt, durationSeconds, sizeBytes, guid
    }
}

public struct CachedProgress: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedProgress"

    public var connectionID: String
    public var itemID: String
    /// Empty string means book-style progress (no episode).
    public var episodeID: String
    public var currentTime: Double
    public var isFinished: Bool
    public var lastUpdate: Int

    public var id: String { connectionID + "/" + itemID + "/" + episodeID }

    public init(
        connectionID: String,
        itemID: String,
        episodeID: String? = nil,
        currentTime: Double,
        isFinished: Bool,
        lastUpdate: Int
    ) {
        self.connectionID = connectionID
        self.itemID = itemID
        self.episodeID = episodeID ?? ""
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
    }

    enum CodingKeys: String, CodingKey {
        case connectionID, itemID, episodeID, currentTime, isFinished, lastUpdate
    }
}

/// Per-book, device-local preferences (Task 7, `v3`): currently just the persisted playback rate,
/// with room in this same row for future per-book prefs (the plan's design intent for `v3`) without
/// another migration. PK `(connectionID, itemID)`, matching every other per-item table in this store.
public struct CachedItemPref: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedItemPref"

    public var connectionID: String
    public var itemID: String
    /// nil = no per-book rate stored — the caller (`AppState.startPlayback`) falls back to the
    /// global default rate setting.
    public var playbackRate: Double?

    public var id: String { connectionID + "/" + itemID }

    public init(connectionID: String, itemID: String, playbackRate: Double? = nil) {
        self.connectionID = connectionID
        self.itemID = itemID
        self.playbackRate = playbackRate
    }
}

public extension Array where Element == CachedProgress {
    /// Indexes a connection's progress rows by `itemID` — the merge rule shared by every
    /// progress-pill surface (Home shelves, the library grid, and M1c-a Task 9's author/series
    /// detail grids): on a collision (a podcast item with several episode rows, or a stale vs.
    /// fresh update), the book-style row (`episodeID` empty) wins over an episode row, else the
    /// newest `lastUpdate` wins. Pulled out of each view's `observeProgress` so the rule is
    /// defined once and is independently testable.
    func indexedByItem() -> [String: CachedProgress] {
        Dictionary(map { ($0.itemID, $0) }) { lhs, rhs in
            if lhs.episodeID.isEmpty != rhs.episodeID.isEmpty {
                return lhs.episodeID.isEmpty ? lhs : rhs
            }
            return lhs.lastUpdate >= rhs.lastUpdate ? lhs : rhs
        }
    }

    /// Indexes a connection's progress rows by the FULL `itemID + "/" + episodeID` key (a book-style
    /// row keys with an empty episode suffix) — M1c-c Task 7, for a podcast-episode shelf card that
    /// must resolve ITS OWN progress row and no other's.
    ///
    /// `indexedByItem()` deliberately COLLAPSES every row sharing an `itemID` down to a single "best"
    /// one, which is correct for a card that shows exactly one pill per item (a book, or a podcast's
    /// own book-style row) — but a PODCAST'S `itemID` is shared by every one of its episodes'
    /// `cachedProgress` rows (the 3-part PK's `itemID` is the podcast, not the episode), so looking an
    /// episode shelf card up via `indexedByItem()` could hand it a SIBLING episode's progress (or,
    /// under that function's book-row-wins collision rule, would even prefer a book-style row that a
    /// podcast item never actually has). Keying by the full `(itemID, episodeID)` pair keeps every
    /// episode's row distinct, so `progressByItemEpisode[itemID + "/" + episodeID]` always resolves
    /// the exact row for that exact episode.
    func indexedByItemAndEpisode() -> [String: CachedProgress] {
        Dictionary(map { ($0.itemID + "/" + $0.episodeID, $0) }) { lhs, rhs in
            lhs.lastUpdate >= rhs.lastUpdate ? lhs : rhs
        }
    }
}
