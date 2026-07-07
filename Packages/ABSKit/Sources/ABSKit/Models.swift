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

/// Full single-item detail from `GET /api/items/:id?expanded=1` — the per-item counterpart to
/// the minified `/items` list page. Used by `ABSClient.item(id:)` for `AppState`'s targeted
/// per-item socket patch (M1c-a Task 3, replacing a coarse full-library `refreshItems` for
/// `item_updated`/`item_added` events) and, in M1c-b, item-detail views. Decodes tolerantly:
/// only the fields Task 3 needs today are modeled here; unknown/future fields (chapters, full
/// relational metadata, progress) are simply ignored by `Decodable`'s default behavior and can
/// be added later without breaking this decode.
public struct LibraryItemDetail: Decodable, Sendable, Identifiable {
    public let id: String
    /// The item's owning library — present on every live server response; optional here only
    /// so a malformed/future response degrades to `AppState`'s `activeLibraryID` fallback
    /// instead of failing the whole decode.
    public let libraryId: String?
    public let updatedAt: Int?
    public let media: ExpandedItemMedia
}

public struct ExpandedItemMedia: Decodable, Sendable {
    public let duration: Double?
    public let metadata: ExpandedItemMetadata
}

/// Mirrors `MinifiedMetadata`'s `title`/`authorName` — `authorName` is a server-computed
/// convenience string (not the raw `authors` relational array), present in both the minified
/// and expanded metadata shapes.
public struct ExpandedItemMetadata: Decodable, Sendable {
    public let title: String?
    public let authorName: String?
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
/// Discriminated structurally (the entity itself carries no explicit `type` tag): a
/// `recentEpisode` key marks a podcast episode entity, a `media` key (with no `recentEpisode`)
/// marks a book/library-item entity, and a `name`+`numBooks` pair (no `media`) marks an author
/// entity. Anything that still fails to decode falls back to `.unknown` rather than throwing, so
/// one unrecognized/future shelf entity never breaks the whole personalized response.
public enum ShelfEntity: Decodable, Sendable {
    case book(ShelfBookEntity)
    case author(ShelfAuthorEntity)
    case episode(ShelfEpisodeEntity)
    case unknown

    private enum DiscriminatorKeys: String, CodingKey { case media, name, numBooks, recentEpisode }

    public init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKeys.self)
        if probe.contains(.recentEpisode), let episode = try? ShelfEpisodeEntity(from: decoder) {
            self = .episode(episode)
        } else if probe.contains(.media), let book = try? ShelfBookEntity(from: decoder) {
            self = .book(book)
        } else if probe.contains(.name), probe.contains(.numBooks), let author = try? ShelfAuthorEntity(from: decoder) {
            self = .author(author)
        } else if let episode = try? ShelfEpisodeEntity(from: decoder) {
            self = .episode(episode)
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
/// podcast library — shelf `type` `"episode"`) are source-verified against ABS 2.35.1
/// (`libraryFilters.js` attaches a `recentEpisode` object onto the podcast's `LibraryItem`
/// before it's pushed onto the shelf) but NOT live-captured: this dev stack seeds a book library
/// only. Every field is optional; M1c-c should tighten this against a real podcast fixture.
public struct ShelfEpisodeEntity: Decodable, Sendable {
    public let id: String?
    public let media: ShelfEntityMedia?
    public let recentEpisode: RecentEpisodeRef?

    public struct RecentEpisodeRef: Decodable, Sendable {
        public let id: String?
        public let title: String?
        public let subtitle: String?
        public let season: String?
        public let episode: String?
        public let publishedAt: Int?
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

/// One row from `GET /api/libraries/:id/series?limit=` (`limit` is REQUIRED by the server —
/// verified live). This dev fixture's library has zero series (`series.json` captures the empty
/// `{results:[],total:0,...}` envelope) — `books` is source-verified only, not live-captured:
/// `seriesFilters.getFilteredSeries` maps each series' books via `LibraryItem.toOldJSONMinified()`,
/// the same minified shape as `LibraryItemSummary`. A richer seed (M1c-c) would strengthen this
/// to a live-captured non-empty fixture.
public struct SeriesSummary: Decodable, Sendable, Identifiable {
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
    /// Podcast-library-only buckets (source-verified via `libraryItemsPodcastFilters.search`,
    /// not live-captured — this dev stack seeds a book library only; M1c-c should tighten this).
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

public struct SearchSeriesHit: Decodable, Sendable {
    public let series: SeriesSummary
    public let books: [LibraryItemSummary]?
}

/// Podcast episode search hits (source-verified only, not live-captured this milestone — see
/// `ShelfEpisodeEntity`).
public struct SearchEpisodeHit: Decodable, Sendable {
    public let id: String?
    public let libraryItemId: String?
    public let title: String?
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
}

/// Source-verified shape (`User.createBookmark`, ABS 2.35.1): `{libraryItemId, time, title,
/// createdAt}` — no `id` field; bookmarks are keyed by `libraryItemId`+`time`, not a UUID.
/// Live-captured non-empty in `me.json` by creating (then deleting, to leave the dev seed
/// unchanged) a real bookmark against the dev server during fixture capture.
public struct Bookmark: Decodable, Sendable, Hashable {
    public let libraryItemId: String
    public let time: Double?
    public let title: String?
    public let createdAt: Int?
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
