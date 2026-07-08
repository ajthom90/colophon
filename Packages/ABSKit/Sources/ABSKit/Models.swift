import Foundation

public struct ServerStatus: Decodable, Sendable {
    public let isInit: Bool
    public let serverVersion: String?
    public let authMethods: [String]?
    public let authFormData: AuthFormData?
}

/// The subset of `/status`'s `authFormData` object the sign-in UI needs to decide what to
/// render: an OIDC button's label, and whether to launch it automatically without waiting for
/// a tap. Server sends more fields (e.g. `authLoginCustomMessage`); unmodeled ones are ignored.
public struct AuthFormData: Decodable, Sendable {
    public let authOpenIDButtonText: String?
    public let authOpenIDAutoLaunch: Bool?
}

public struct LoginResponse: Decodable, Sendable {
    public let user: User
    public let userDefaultLibraryId: String?
}

public struct User: Decodable, Sendable {
    public let id: String
    public let username: String
    public let accessToken: String?
    public let refreshToken: String?
}

public struct LibrariesResponse: Decodable, Sendable { public let libraries: [Library] }

public struct Library: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let mediaType: String
    public let icon: String?
    public let displayOrder: Int?
}

public struct ItemsPage: Decodable, Sendable {
    public let results: [LibraryItemSummary]
    public let total: Int
    public let limit: Int
    public let page: Int
}

public struct LibraryItemSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let updatedAt: Int?
    public let media: MinifiedMedia
}

public struct MinifiedMedia: Decodable, Sendable, Hashable {
    public let duration: Double?
    public let metadata: MinifiedMetadata
}

public struct MinifiedMetadata: Decodable, Sendable, Hashable {
    public let title: String?
    public let authorName: String?
}

/// Full single-item detail from `GET /api/items/:id?expanded=1&include=progress` — the per-item
/// counterpart to the minified `/items` list page. Used by `ABSClient.item(id:)` for `AppState`'s
/// targeted per-item socket patch (M1c-a Task 3, replacing a coarse full-library `refreshItems`
/// for `item_updated`/`item_added` events) and, in M1c-b, `ItemDetailView`. Decodes tolerantly:
/// every added field is optional, so an older/variant/partial server response never fails the
/// whole decode (the Task 3 socket-patch path only reads `id`/`libraryId`/`updatedAt`/`media.
/// metadata.title`/`authorName`/`media.duration`, all of which predate this expansion).
///
/// Field shapes are grounded in a live ABS 2.35.1 capture (this milestone) — see the endpoint
/// reference: `media.chapters` are GLOBAL book seconds, `userMediaProgress` rides at the TOP
/// level of the response (NOT under `media`), and metadata carries the server-computed
/// `authorName`/`narratorName`/`seriesName` convenience strings alongside the relational arrays.
public struct LibraryItemDetail: Decodable, Sendable, Identifiable {
    public let id: String
    /// The item's owning library — present on every live server response; optional here only
    /// so a malformed/future response degrades to `AppState`'s `activeLibraryID` fallback
    /// instead of failing the whole decode.
    public let libraryId: String?
    public let updatedAt: Int?
    public let media: ExpandedItemMedia
    /// The signed-in user's progress for this item — only present with `include=progress`.
    public let userMediaProgress: UserMediaProgress?
}

public struct ExpandedItemMedia: Decodable, Sendable {
    public let duration: Double?
    public let metadata: ExpandedItemMetadata
    /// Chapter marks in GLOBAL book seconds (`{id,start,end,title}`), for the chapters preview.
    public let chapters: [Chapter]?
}

/// Expanded book metadata. `authorName`/`narratorName`/`seriesName` are server-computed
/// convenience strings (flattened from the relational `authors`/`narrators`/`series` arrays);
/// `series` carries the per-series `sequence` the convenience string drops. Empty strings appear
/// live for absent narrator/series (verified) — the UI treats "" as absent.
public struct ExpandedItemMetadata: Decodable, Sendable {
    public let title: String?
    public let subtitle: String?
    public let authorName: String?
    public let narratorName: String?
    public let seriesName: String?
    public let series: [SeriesRef]?
    public let genres: [String]?
    public let publishedYear: String?
    public let publishedDate: String?
    public let publisher: String?
    public let description: String?
    public let isbn: String?
    public let asin: String?
    public let language: String?
    public let explicit: Bool?
    public let abridged: Bool?
}

/// One entry of a book's `metadata.series` — the series identity plus this book's `sequence`
/// within it (e.g. `"1"`, `"2.5"`, or absent). `sequence` is a string, not a number: ABS stores
/// fractional/lettered sequences. `id`/`name` are optional so a malformed/future series element
/// degrades to "no series label" instead of failing the whole `LibraryItemDetail` decode (the
/// enclosing `series: [SeriesRef]?` is meant to be tolerant); the UI guards on a non-empty `name`.
public struct SeriesRef: Decodable, Sendable, Identifiable, Hashable {
    public let id: String?
    public let name: String?
    public let sequence: String?
}

/// The signed-in user's progress for an item, from `GET /api/items/:id?include=progress`'s
/// top-level `userMediaProgress`. Mirrors the fields `ItemDetailView` needs for its Resume state;
/// all optional for tolerant decoding.
public struct UserMediaProgress: Decodable, Sendable, Hashable {
    public let currentTime: Double?
    public let progress: Double?
    public let duration: Double?
    public let isFinished: Bool?
}

public struct PlaybackSession: Decodable, Sendable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let displayTitle: String?
    public let displayAuthor: String?
    public let duration: Double
    public let startTime: Double
    public let currentTime: Double?
    public let playMethod: Int
    public let audioTracks: [AudioTrack]
    public let chapters: [Chapter]
}

public struct AudioTrack: Decodable, Sendable {
    public let index: Int
    public let startOffset: Double
    public let duration: Double
    public let title: String?
    public let contentUrl: String?
    public let mimeType: String?
}

public struct Chapter: Decodable, Sendable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String?
}

// MARK: - Browse, search, and me (Task 5)

/// One "shelf" from `GET /api/libraries/:id/personalized?limit=` — a labeled horizontal row of
/// entities. Live-verified shelf `type`s for a book library: `book` (Continue Listening, Recently
/// Added) and `authors` (Newest Authors); podcast libraries add `episode`-typed shelves
/// (source-verified only this milestone — see `ShelfEpisodeEntity`). Entities carry NO progress
/// field (verified live) — the caller joins `MeUser.mediaProgress`/`CachedProgress` instead.
public struct Shelf: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let type: String
    public let entities: [ShelfEntity]
}

/// Tolerant sum type over the three live/source-verified personalized-shelf entity shapes.
/// Discriminated structurally (the entity itself carries no explicit `type` tag) by requiring a
/// DISTINGUISHING key per variant — the episode/author/book structs all have permissive
/// (mostly-optional) fields, so a `try?`-cascade over them would misclassify any bare object;
/// the discriminator check below is what makes classification meaningful:
/// - `recentEpisode` present → podcast-episode entity (its one distinguishing key per source).
/// - else `media` present → book/library-item entity (book entities nest `media.metadata`).
/// - else `name` AND `numBooks` present → author entity.
/// - else → `.unknown` (a genuinely unrecognized/future shape never throws or misdecodes).
public enum ShelfEntity: Decodable, Sendable {
    case book(ShelfBookEntity)
    case author(ShelfAuthorEntity)
    case episode(ShelfEpisodeEntity)
    case unknown

    private enum DiscriminatorKeys: String, CodingKey { case media, name, numBooks, recentEpisode }

    public init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKeys.self)
        if probe.contains(.recentEpisode) {
            self = .episode(try ShelfEpisodeEntity(from: decoder))
        } else if probe.contains(.media) {
            self = .book(try ShelfBookEntity(from: decoder))
        } else if probe.contains(.name), probe.contains(.numBooks) {
            self = .author(try ShelfAuthorEntity(from: decoder))
        } else {
            self = .unknown
        }
    }
}

public struct ShelfBookEntity: Decodable, Sendable, Identifiable {
    public let id: String
    public let media: ShelfEntityMedia
}

/// Shared media projection for shelf book entities AND search's `book` bucket (verified live:
/// both endpoints nest `coverPath`/`duration`/`metadata` identically alongside a `media.id`).
public struct ShelfEntityMedia: Decodable, Sendable {
    public let coverPath: String?
    public let duration: Double?
    public let metadata: ShelfEntityMetadata
}

public struct ShelfEntityMetadata: Decodable, Sendable {
    public let title: String?
    public let subtitle: String?
    public let authorName: String?
    public let narratorName: String?
    public let seriesName: String?
}

public struct ShelfAuthorEntity: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let imagePath: String?
    public let numBooks: Int?
}

/// Podcast episode shelf entities (`continue-listening`/`newest-episodes`/`listen-again` on a
/// podcast library — shelf `type` `"episode"`) — LIVE-CAPTURED (M1c-c Task 1,
/// `podcast-personalized.json`). ABS's `libraryFilters.js` attaches a `recentEpisode` object onto
/// the podcast's `LibraryItem` before it's pushed onto the shelf, so the entity itself is the
/// PODCAST library item (`id` = podcast item id, `media` = podcast media) with the shelf's episode
/// riding in `recentEpisode`.
///
/// Live corrections over the M1c-a source-only guess: `id` is always present (it's the podcast
/// library-item id, NOT the episode id — the episode id lives at `recentEpisode.id`), so it's
/// non-optional to match `ShelfBookEntity`/`ShelfAuthorEntity`. `RecentEpisodeRef` gained the
/// fields the live projection actually carries — `libraryItemId` (the podcast id, for the 3-part
/// `cachedProgress` PK join), `episodeType`, `index`, `pubDate`, `guid`, `description`, `duration`.
/// `season`/`episode` are STRINGS (verified: `"1"`, not `1`); `index` and `duration` come back
/// `null` in this shelf projection (present on the full item), so both stay optional.
public struct ShelfEpisodeEntity: Decodable, Sendable {
    /// The PODCAST library-item id (the shelf entity is the podcast, not the episode).
    public let id: String
    public let media: ShelfEntityMedia?
    public let recentEpisode: RecentEpisodeRef?

    public struct RecentEpisodeRef: Decodable, Sendable {
        /// The episode id (the id used for `/play/:episodeId` and the `cachedProgress` PK).
        public let id: String?
        /// The owning podcast's library-item id (the `itemID` of the 3-part `cachedProgress` PK).
        public let libraryItemId: String?
        public let index: Int?
        public let season: String?
        public let episode: String?
        public let episodeType: String?
        public let title: String?
        public let subtitle: String?
        public let description: String?
        public let pubDate: String?
        public let publishedAt: Int?
        public let guid: String?
        public let duration: Double?
    }
}

/// `GET /api/libraries/:id/filterdata` — the full set of distinct facet values for a library's
/// filter/sort UI (Task 8's `FilterSheet`) plus a handful of summary counts.
public struct FilterData: Decodable, Sendable {
    public let authors: [FilterAuthor]
    public let series: [FilterSeries]
    public let genres: [String]
    public let tags: [String]
    public let narrators: [String]
    public let languages: [String]
    public let publishers: [String]
    public let publishedDecades: [String]
    public let bookCount: Int?
    public let authorCount: Int?
    public let seriesCount: Int?
    public let podcastCount: Int?
    public let numIssues: Int?
    public let loadedAt: Int?
}

public struct FilterAuthor: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
}

public struct FilterSeries: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
}

/// One row from `GET /api/libraries/:id/series?limit=`. The server ACCEPTS an omitted `limit`
/// (verified live: `GET .../series` with no `limit` returns HTTP 200 `{results:[],total:0,
/// limit:0,...}`, NOT a 400) — but `limit:0` yields zero results, so the app must pass an
/// explicit `limit` to get rows back. This dev fixture's library has zero series (`series.json`
/// captures the empty envelope) — `books` is source-verified only, not live-captured:
/// `seriesFilters.getFilteredSeries` maps each series' books via `LibraryItem.toOldJSONMinified()`,
/// the same minified shape as `LibraryItemSummary`. A richer seed (M1c-c) would strengthen this
/// to a live-captured non-empty fixture.
///
/// `Hashable` (all stored properties already are) so Task 9's `SeriesListView` can push
/// `SeriesDetailView` via the codebase's standard `NavigationLink(value:)` +
/// `navigationDestination(for:)` pattern, matching `AuthorSummary` and `CachedLibrary`.
public struct SeriesSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let books: [LibraryItemSummary]?
}

struct SeriesListResponse: Decodable, Sendable {
    let results: [SeriesSummary]
    let total: Int
}

/// One row from `GET /api/libraries/:id/authors` (`authors[]`) — also reused, since it's
/// structurally identical per source (`authorFilters.search` → `Author.toOldJSONExpanded`), for
/// the `authors` bucket of `searchLibrary`'s results (verified live: `search-sun.json`'s
/// `authors` entries simply omit `lastFirst`, which decodes fine since it's optional).
public struct AuthorSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let numBooks: Int?
    public let imagePath: String?
    public let asin: String?
    public let description: String?
    public let lastFirst: String?
}

struct AuthorsResponse: Decodable, Sendable {
    let authors: [AuthorSummary]
}

/// `GET /api/authors/:id?include=items` — `libraryItems` is populated only when `include`
/// contains `items` (verified against ABS `AuthorController.findOne`); optional here so a call
/// without that include still decodes.
public struct AuthorDetail: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let imagePath: String?
    public let asin: String?
    public let description: String?
    public let libraryItems: [LibraryItemSummary]?
}

/// `GET /api/libraries/:id/search?q=&limit=` — per-library only.
///
/// **Caller contract (server enforces via 400; does not degrade gracefully — verified live:
/// both an empty `q=` and an omitted `q` param 400):** never call `searchLibrary` with an
/// empty query, and treat anything under ~2 characters as not worth sending — guard client-side.
///
/// **Match-bucket behavior (verified live via `search-art.json`/`search-sun.json`):** the `book`
/// bucket matches title/subtitle/isbn/asin ONLY — it does NOT match author name. A query that
/// only matches an author (e.g. "sun" → "Sun Tzu") returns an EMPTY `book` bucket, with the hit
/// surfacing instead in the `authors` bucket. UI must render both buckets, not just `book`.
public struct SearchResults: Decodable, Sendable {
    public let book: [SearchBookHit]?
    public let narrators: [SearchNamedCount]?
    public let tags: [SearchNamedCount]?
    public let genres: [SearchNamedCount]?
    public let series: [SearchSeriesHit]?
    public let authors: [AuthorSummary]?
    /// Podcast-library-only buckets — LIVE-CAPTURED (M1c-c Task 1, `podcast-search.json`,
    /// `q=on` matching both). The `podcast` bucket is verified to reuse the SAME `{libraryItem}`
    /// wrapper as the `book` bucket (so `[SearchBookHit]` is correct); the `episodes` bucket wraps
    /// the matched episode's PODCAST, with the matched episode in `libraryItem.recentEpisode` (see
    /// `SearchEpisodeHit`). Book libraries omit both buckets entirely (they decode as nil).
    public let podcast: [SearchBookHit]?
    public let episodes: [SearchEpisodeHit]?
}

public struct SearchBookHit: Decodable, Sendable, Identifiable {
    public let libraryItem: SearchLibraryItem
    public var id: String { libraryItem.id }
}

/// Lean projection of the search endpoint's `book[].libraryItem` — verified live to be the SAME
/// fully expanded item shape as `GET /api/items/:id?expanded=1` (audioFiles/libraryFiles/tracks
/// included), but a search result row only needs id/cover/duration/metadata; everything else is
/// dropped by tolerant decoding.
public struct SearchLibraryItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let media: ShelfEntityMedia
}

/// Narrators/tags/genres match buckets — narrators report `numBooks`, tags/genres report
/// `numItems` (verified against the live query source); both fields optional so one struct
/// serves all three.
public struct SearchNamedCount: Decodable, Sendable {
    public let name: String
    public let numBooks: Int?
    public let numItems: Int?
}

/// A `series` search bucket hit. Source-verified only, not live-captured: both search fixtures
/// (`search-art.json`/`search-sun.json`) have an empty `series:[]` because the seeded library
/// has no series. `libraryItemsBookFilters.search` maps each hit to `{series, books[]}` where
/// `books` are `LibraryItem.toOldJSON()` rows. M1c-c should tighten this against a live series
/// fixture.
public struct SearchSeriesHit: Decodable, Sendable {
    public let series: SeriesSummary
    public let books: [LibraryItemSummary]?
}

/// A `episodes` search-bucket hit — LIVE-CAPTURED (M1c-c Task 1, `podcast-search.json`).
///
/// Live correction over the M1c-a source-only guess (`{id, libraryItemId, title}`): the real hit
/// wraps a `libraryItem` (the matched episode's PODCAST — `mediaType: "podcast"`), and the matched
/// episode rides in `libraryItem.recentEpisode` — `media.episodes` is EMPTY in this search
/// projection, exactly like a personalized episode shelf entity. So the hit mirrors `SearchBookHit`
/// (a `{libraryItem}` wrapper), not a flat episode object; read the episode from `recentEpisode`.
public struct SearchEpisodeHit: Decodable, Sendable, Identifiable {
    public let libraryItem: SearchEpisodeLibraryItem
    /// The matched episode's id (falls back to the podcast id) — stable for SwiftUI `ForEach`.
    public var id: String { libraryItem.recentEpisode?.id ?? libraryItem.id }
}

/// The `libraryItem` wrapper inside an `episodes` search hit: the matched episode's PODCAST
/// (`id`/`media` for the podcast title + cover) plus the matched episode in `recentEpisode`
/// (reusing `ShelfEpisodeEntity.RecentEpisodeRef`, the identical shape verified live). Lean
/// projection — the search response's other item fields (path/ino/libraryFiles/…) are dropped by
/// tolerant decoding.
public struct SearchEpisodeLibraryItem: Decodable, Sendable, Identifiable {
    /// The podcast library-item id.
    public let id: String
    public let media: ShelfEntityMedia
    public let recentEpisode: ShelfEpisodeEntity.RecentEpisodeRef?
}

/// `GET /api/me` — this milestone only needs `mediaProgress` (the progress-join source for
/// shelves, since shelf entities carry no progress — verified live) and `bookmarks` (for the
/// M1c-b player). Everything else on the user object (permissions, libraries, etc.) is ignored.
public struct MeUser: Decodable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let mediaProgress: [MediaProgressEntry]?
    public let bookmarks: [Bookmark]?
}

public struct MediaProgressEntry: Decodable, Sendable, Hashable {
    public let libraryItemId: String
    public let episodeId: String?
    public let progress: Double?
    public let currentTime: Double?
    public let duration: Double?
    public let isFinished: Bool?
    /// Server-side last-modified timestamp (ms since epoch). Optional so an older/variant server
    /// response still decodes; the progress-join uses it for last-write-wins reconciliation
    /// against socket `progressUpdated` events (which carry the same server timestamp), falling
    /// back to wall-clock time only when absent.
    public let lastUpdate: Int?
}

/// Verified live (ABS 2.35.1, M1c-b Task 1): `POST`/`PATCH /api/me/item/:id/bookmark` and the
/// `bookmarks[]` entries on `GET /api/me` all share this shape — `{libraryItemId, time, title,
/// createdAt}`, no server-assigned `id` field; bookmarks are keyed by `libraryItemId`+`time`.
/// `time` decodes as `Double` (not `Int`) because it's a plain JS number with no schema-enforced
/// integrality: sending an integer `time` round-trips as an integer (`bookmark.json`'s captured
/// fixture), but sending a fractional `time` (verified live this session) round-trips fractional
/// too — `ABSClient.createBookmark`/`updateBookmark` only ever send whole seconds, but a tolerant
/// decode must not reject a bookmark some OTHER client created with sub-second precision.
/// `Identifiable` (`id` derived from `libraryItemId`+`time`, the server's own composite key) lets
/// SwiftUI's `List`/`ForEach` key bookmark rows without a synthesized UUID that would change
/// every reconcile-from-`/api/me` refresh.
public struct Bookmark: Codable, Sendable, Hashable, Identifiable {
    public let libraryItemId: String
    public let time: Double?
    public let title: String?
    public let createdAt: Int?

    public var id: String { "\(libraryItemId)#\(time.map { String($0) } ?? "nil")" }

    public init(libraryItemId: String, time: Double?, title: String?, createdAt: Int?) {
        self.libraryItemId = libraryItemId
        self.time = time
        self.title = title
        self.createdAt = createdAt
    }
}

public struct DeviceInfo: Encodable, Sendable {
    public let deviceId: String
    public let clientName: String
    public let clientVersion: String
    public let manufacturer: String
    public let model: String
    public init(deviceId: String, clientName: String = "Colophon",
                clientVersion: String, manufacturer: String = "Apple", model: String) {
        self.deviceId = deviceId; self.clientName = clientName
        self.clientVersion = clientVersion; self.manufacturer = manufacturer; self.model = model
    }
}
