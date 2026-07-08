import Foundation
import Testing
@testable import ABSKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

@Suite struct ModelDecodingTests {
    private let decoder = JSONDecoder()

    @Test func decodesServerStatus() throws {
        let s = try decoder.decode(ServerStatus.self, from: fixture("status"))
        #expect(s.isInit == true)
        #expect(s.serverVersion == "2.35.1")
        #expect(s.authMethods == ["local"])
    }

    /// Captured from the Task 5 dev stack's real `/status` once Dex/OIDC is seeded — exercises
    /// `authFormData`'s OIDC fields, which `ConnectView` needs to render/auto-launch the SSO button.
    @Test func decodesServerStatusWithOpenIDAuthFormData() throws {
        let s = try decoder.decode(ServerStatus.self, from: fixture("status_openid"))
        #expect(s.authMethods == ["local", "openid"])
        #expect(s.authFormData?.authOpenIDButtonText == "Sign in with Dex")
        #expect(s.authFormData?.authOpenIDAutoLaunch == false)
    }

    @Test func decodesLoginResponseWithTokens() throws {
        let r = try decoder.decode(LoginResponse.self, from: fixture("login"))
        #expect(r.user.accessToken == "eyJ.access.1")
        #expect(r.user.refreshToken == "eyJ.refresh.1")
        #expect(r.user.username == "root")
    }

    @Test func decodesLibraries() throws {
        let r = try decoder.decode(LibrariesResponse.self, from: fixture("libraries"))
        #expect(r.libraries.count == 1)
        #expect(r.libraries[0].mediaType == "book")
        #expect(r.libraries[0].name == "Books")
    }

    @Test func decodesItemsPage() throws {
        let p = try decoder.decode(ItemsPage.self, from: fixture("items_page"))
        #expect(p.total == 1)
        #expect(p.results[0].media.metadata.title == "The Art of War")
        #expect(p.results[0].media.metadata.authorName == "Sun Tzu")
        #expect(p.results[0].updatedAt == 1_751_060_000_000)
    }

    @Test func decodesPlaybackSession() throws {
        let s = try decoder.decode(PlaybackSession.self, from: fixture("playback_session"))
        #expect(s.id == "ses_xyz789")
        #expect(s.startTime == 125.0)
        #expect(s.audioTracks.count == 2)
        #expect(s.audioTracks[1].startOffset == 600.2)
        #expect(s.audioTracks[1].index == 2)
        #expect(s.chapters.count == 2)
    }

    @Test func toleratesUnknownAndMissingFields() throws {
        let json = #"{"id":"ses_1","libraryItemId":"li_9","duration":10,"playMethod":0,"startTime":0,"currentTime":0,"audioTracks":[],"chapters":[],"someFutureField":{"x":1}}"#
        let s = try decoder.decode(PlaybackSession.self, from: Data(json.utf8))
        #expect(s.displayTitle == nil)
        #expect(s.audioTracks.isEmpty)
    }

    @Test func decodesPersonalizedShelves() throws {
        let shelves = try decoder.decode([Shelf].self, from: fixture("personalized"))
        #expect(shelves.count == 3)
        #expect(shelves[0].id == "continue-listening")
        #expect(shelves[0].type == "book")
        guard case let .book(entity) = shelves[0].entities.first else {
            Issue.record("expected a book shelf entity")
            return
        }
        #expect(entity.id == "77226f9e-ad94-4b26-bf8a-bf841965ca23")
        #expect(entity.media.metadata.title == "The Art of War")
        #expect(entity.media.metadata.authorName == "Sun Tzu")
        #expect(entity.media.coverPath == "/audiobooks/Sun Tzu/The Art of War/cover.jpg")
        #expect(entity.media.duration == 4337.264399)

        let authorsShelf = shelves[2]
        #expect(authorsShelf.id == "newest-authors")
        #expect(authorsShelf.type == "authors")
        guard case let .author(authorEntity) = authorsShelf.entities.first else {
            Issue.record("expected an author shelf entity")
            return
        }
        #expect(authorEntity.name == "Sun Tzu")
        #expect(authorEntity.numBooks == 1)
    }

    /// A shelf entity with none of the discriminating keys (`media`/`recentEpisode`/
    /// `name`+`numBooks`) must decode as `.unknown` — NOT silently misclassify as an all-nil
    /// `.episode` (regression guard for the tolerant-but-not-lax discrimination).
    @Test func unknownShelfEntityShapeFallsBackToUnknown() throws {
        let json = #"{"id":"x","weirdField":1}"#
        let entity = try decoder.decode(ShelfEntity.self, from: Data(json.utf8))
        guard case .unknown = entity else {
            Issue.record("expected .unknown, got \(entity)")
            return
        }
    }

    @Test func decodesFilterData() throws {
        let f = try decoder.decode(FilterData.self, from: fixture("filterdata"))
        #expect(f.authors.map(\.name) == ["Sun Tzu"])
        #expect(f.genres.isEmpty)
        #expect(f.bookCount == 1)
        #expect(f.authorCount == 1)
        #expect(f.seriesCount == 0)
    }

    /// This dev fixture's library has no series — asserts the empty-shape decode. Non-empty
    /// `books` field names are source-verified only (see the doc comment on `SeriesSummary`).
    @Test func decodesEmptySeriesList() throws {
        let r = try decoder.decode(SeriesListResponse.self, from: fixture("series"))
        #expect(r.results.isEmpty)
        #expect(r.total == 0)
    }

    @Test func decodesAuthors() throws {
        let r = try decoder.decode(AuthorsResponse.self, from: fixture("authors"))
        #expect(r.authors.count == 1)
        #expect(r.authors[0].name == "Sun Tzu")
        #expect(r.authors[0].numBooks == 1)
        #expect(r.authors[0].lastFirst == "Tzu, Sun")
    }

    @Test func decodesAuthorDetail() throws {
        let a = try decoder.decode(AuthorDetail.self, from: fixture("author"))
        #expect(a.name == "Sun Tzu")
        #expect(a.libraryItems?.count == 1)
        #expect(a.libraryItems?.first?.media.metadata.title == "The Art of War")
    }

    @Test func decodesSearchResultsWithBookMatch() throws {
        let r = try decoder.decode(SearchResults.self, from: fixture("search-art"))
        #expect(r.book?.count == 1)
        #expect(r.book?.first?.libraryItem.media.metadata.title == "The Art of War")
        #expect(r.authors?.isEmpty == true)
    }

    /// Proves the match-bucket behavior documented on `ABSClient.searchLibrary`: a query that
    /// only matches an author name returns an EMPTY `book` bucket, with the hit surfacing in
    /// `authors` instead.
    @Test func decodesSearchResultsWithAuthorMatchProvesEmptyBookBucket() throws {
        let r = try decoder.decode(SearchResults.self, from: fixture("search-sun"))
        #expect(r.book?.isEmpty == true)
        #expect(r.authors?.count == 1)
        #expect(r.authors?.first?.name == "Sun Tzu")
    }

    @Test func decodesMeWithProgressAndBookmarks() throws {
        let me = try decoder.decode(MeUser.self, from: fixture("me"))
        #expect(me.username == "root")
        #expect(me.mediaProgress?.count == 1)
        #expect(me.mediaProgress?.first?.libraryItemId == "77226f9e-ad94-4b26-bf8a-bf841965ca23")
        #expect(me.mediaProgress?.first?.currentTime == 120.5)
        #expect(me.bookmarks?.count == 1)
        #expect(me.bookmarks?.first?.title == "Interesting chapter")
        #expect(me.bookmarks?.first?.time == 100.5)
    }

    /// `Tests/ABSKitTests/Fixtures/bookmark.json` is a REAL response captured live this session:
    /// `POST /api/me/item/77226f9e-ad94-4b26-bf8a-bf841965ca23/bookmark {"time":142,"title":
    /// "Interesting chapter"}` against the dev server, then the bookmark was DELETEd again to
    /// leave the seed clean (see `ABSClient.createBookmark`/`deleteBookmark`).
    @Test func decodesCreatedBookmarkFixture() throws {
        let b = try decoder.decode(Bookmark.self, from: fixture("bookmark"))
        #expect(b.libraryItemId == "77226f9e-ad94-4b26-bf8a-bf841965ca23")
        #expect(b.time == 142)
        #expect(b.title == "Interesting chapter")
        #expect(b.createdAt == 1_783_509_180_098)
        #expect(b.id == "77226f9e-ad94-4b26-bf8a-bf841965ca23#142.0")
    }

    /// `Tests/ABSKitTests/Fixtures/item_detail.json` mirrors a live `GET /api/items/:id?expanded=1
    /// &include=progress` capture (ABS 2.35.1) — the real item/library IDs, `media.duration`, all 7
    /// chapters (GLOBAL seconds) and `userMediaProgress` are exactly as captured; the sparse seed
    /// book's null metadata fields (subtitle/series/genres/publisher/isbn/asin/narrator) are filled
    /// with representative values so this decode exercises the full expanded DTO, incl. the
    /// per-series `sequence` the flattened `seriesName` string drops.
    @Test func decodesExpandedItemDetailFixture() throws {
        let d = try decoder.decode(LibraryItemDetail.self, from: fixture("item_detail"))
        #expect(d.id == "77226f9e-ad94-4b26-bf8a-bf841965ca23")
        #expect(d.libraryId == "51724195-018f-4681-8c35-ae1575350473")
        #expect(d.media.duration == 4337.264399)
        #expect(d.media.metadata.title == "The Art of War")
        #expect(d.media.metadata.authorName == "Sun Tzu")
        #expect(d.media.metadata.narratorName == "Jane Reader")
        #expect(d.media.metadata.genres == ["History", "Philosophy"])
        #expect(d.media.metadata.publisher == "Test Press")
        #expect(d.media.metadata.isbn == "9780000000001")
        #expect(d.media.metadata.series?.first?.name == "Military Classics")
        #expect(d.media.metadata.series?.first?.sequence == "1")
        #expect(d.media.chapters?.count == 7)
        #expect(d.media.chapters?.first?.start == 0)
        #expect(d.media.chapters?.first?.title == "1 Laying Plans - 2 Waging War")
        #expect(d.userMediaProgress?.currentTime == 30)
        #expect(d.userMediaProgress?.isFinished == false)
    }

    /// A malformed/partial `metadata.series` element (missing `id` AND `name`) must NOT fail the
    /// whole `LibraryItemDetail` decode — `SeriesRef.id`/`name` are optional so a bad series entry
    /// just drops its label. Proves the tolerant-decode contract of `series: [SeriesRef]?`.
    @Test func tolerantSeriesRefDoesNotFailItemDecode() throws {
        let json = Data("""
        {
          "id": "item-1",
          "libraryId": "lib-1",
          "media": {
            "metadata": {
              "title": "Partial Book",
              "series": [ { "sequence": "3" }, { "id": "s2", "name": "Real Series" } ]
            }
          }
        }
        """.utf8)
        let d = try decoder.decode(LibraryItemDetail.self, from: json)
        #expect(d.id == "item-1")
        #expect(d.media.metadata.title == "Partial Book")
        // First element decoded with nil id/name (label-less); the second kept its real name.
        #expect(d.media.metadata.series?.count == 2)
        #expect(d.media.metadata.series?.first?.name == nil)
        #expect(d.media.metadata.series?.first?.sequence == "3")
        #expect(d.media.metadata.series?.last?.name == "Real Series")
    }

    // MARK: - Podcast fixtures (M1c-c Task 1 — live-captured against a real seeded podcast)

    /// `podcast-personalized.json` is a live `GET /api/libraries/:podcastLib/personalized` capture
    /// (ABS 2.35.1) for the seeded "Colophon Test Podcast": episode-typed shelves
    /// (`continue-listening`/`newest-episodes`, shelf `type` `"episode"`) plus a `podcast`-typed
    /// `recently-added`. Grounds `ShelfEpisodeEntity`: the entity `id` is the PODCAST item id, the
    /// matched episode rides in `recentEpisode`, and `season`/`episode` are STRINGS.
    @Test func decodesPodcastPersonalizedEpisodeShelves() throws {
        let shelves = try decoder.decode([Shelf].self, from: fixture("podcast-personalized"))
        let continueShelf = try #require(shelves.first { $0.id == "continue-listening" })
        #expect(continueShelf.type == "episode")
        guard case let .episode(ep) = continueShelf.entities.first else {
            Issue.record("expected an episode shelf entity")
            return
        }
        // The entity id is the PODCAST library-item id, not the episode id.
        #expect(ep.id == "55967a7a-0b3e-4a2c-aaf9-45843286117a")
        #expect(ep.media?.metadata.title == "Colophon Test Podcast")
        #expect(ep.media?.coverPath == "/podcasts/Colophon Test Podcast/cover.jpg")
        // The episode itself lives in recentEpisode.
        #expect(ep.recentEpisode?.id == "5753ddd5-fa18-4513-a0a8-2aee528f5e4d")
        #expect(ep.recentEpisode?.libraryItemId == "55967a7a-0b3e-4a2c-aaf9-45843286117a")
        #expect(ep.recentEpisode?.title == "Episode One: Laying Plans")
        #expect(ep.recentEpisode?.subtitle == "The opening chapter on strategy")
        #expect(ep.recentEpisode?.season == "1")       // STRING, not Int
        #expect(ep.recentEpisode?.episode == "1")      // STRING, not Int
        #expect(ep.recentEpisode?.episodeType == "full")
        #expect(ep.recentEpisode?.publishedAt == 1_736_150_400_000)
        #expect(ep.recentEpisode?.guid == "colophon-test-ep-0001")
        // index/duration come back null in the shelf projection — optionality verified.
        #expect(ep.recentEpisode?.index == nil)
        #expect(ep.recentEpisode?.duration == nil)

        #expect(shelves.contains { $0.id == "newest-episodes" && $0.type == "episode" })
        #expect(shelves.contains { $0.id == "recently-added" && $0.type == "podcast" })
    }

    /// `podcast-search.json` is a live `GET /api/libraries/:podcastLib/search?q=on` capture: `q=on`
    /// matches both the podcast title ("Colophon") and an episode title ("Episode One"), so both
    /// podcast-only buckets are populated. Grounds `SearchResults.podcast` (a `{libraryItem}`
    /// wrapper, same as `book`) and the corrected `SearchEpisodeHit` (the matched episode rides in
    /// `libraryItem.recentEpisode`, NOT a flat `{id,libraryItemId,title}` object).
    @Test func decodesPodcastSearchBuckets() throws {
        let r = try decoder.decode(SearchResults.self, from: fixture("podcast-search"))
        #expect(r.podcast?.count == 1)
        #expect(r.podcast?.first?.libraryItem.id == "55967a7a-0b3e-4a2c-aaf9-45843286117a")
        #expect(r.podcast?.first?.libraryItem.media.metadata.title == "Colophon Test Podcast")

        #expect(r.episodes?.count == 1)
        let hit = try #require(r.episodes?.first)
        #expect(hit.libraryItem.id == "55967a7a-0b3e-4a2c-aaf9-45843286117a")  // podcast id
        #expect(hit.libraryItem.media.metadata.title == "Colophon Test Podcast")
        #expect(hit.libraryItem.recentEpisode?.title == "Episode One: Laying Plans")
        #expect(hit.libraryItem.recentEpisode?.id == "5753ddd5-fa18-4513-a0a8-2aee528f5e4d")
        // Identifiable id resolves to the matched episode id (stable for ForEach).
        #expect(hit.id == "5753ddd5-fa18-4513-a0a8-2aee528f5e4d")
    }

    /// `me-episode-progress.json` is a live `GET /api/me` capture taken after setting per-episode
    /// progress. Grounds `MediaProgressEntry.episodeId`: a book entry carries `episodeId: null`
    /// (decodes nil), an episode entry carries a populated `episodeId` — the discriminator the
    /// 3-part `cachedProgress` PK relies on ("" = book, episodeId = episode).
    @Test func decodesMeWithEpisodeProgress() throws {
        let me = try decoder.decode(MeUser.self, from: fixture("me-episode-progress"))
        let progress = try #require(me.mediaProgress)
        #expect(progress.count == 2)
        let episodeEntry = try #require(progress.first { $0.episodeId != nil })
        #expect(episodeEntry.libraryItemId == "55967a7a-0b3e-4a2c-aaf9-45843286117a")
        #expect(episodeEntry.episodeId == "5753ddd5-fa18-4513-a0a8-2aee528f5e4d")
        #expect(episodeEntry.currentTime == 123.5)
        #expect(episodeEntry.isFinished == false)
        // The book entry has a null episodeId (decodes nil) — distinct progress row.
        let bookEntry = try #require(progress.first { $0.episodeId == nil })
        #expect(bookEntry.libraryItemId == "77226f9e-ad94-4b26-bf8a-bf841965ca23")
    }

    /// `episode-play.json` is a live `POST /api/items/:id/play/:episodeId` capture (the session was
    /// closed immediately after to leave the seed clean). Confirms the episode playback envelope is
    /// the SAME `PlaybackSession` shape as a book `/play`, with `episodeId` populated and the
    /// episode's title/podcast surfaced as `displayTitle`/`displayAuthor`.
    @Test func decodesEpisodePlaybackSession() throws {
        let s = try decoder.decode(PlaybackSession.self, from: fixture("episode-play"))
        #expect(s.id == "8c948009-d896-4e3f-aeb4-4ec53ff01c47")
        #expect(s.libraryItemId == "55967a7a-0b3e-4a2c-aaf9-45843286117a")
        #expect(s.episodeId == "5753ddd5-fa18-4513-a0a8-2aee528f5e4d")
        #expect(s.displayTitle == "Episode One: Laying Plans")
        #expect(s.displayAuthor == "Colophon Dev")
        #expect(s.duration == 465.397551)
        #expect(s.playMethod == 0)
        #expect(s.audioTracks.count == 1)
        #expect(s.audioTracks.first?.contentUrl == "/api/items/55967a7a-0b3e-4a2c-aaf9-45843286117a/file/5521")
    }

    @Test func deviceInfoEncodesWithDefaults() throws {
        let device = DeviceInfo(deviceId: "dev-1", clientVersion: "0.1.0", model: "Mac16,1")
        let data = try JSONEncoder().encode(device)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(json == [
            "deviceId": "dev-1",
            "clientName": "Colophon",
            "clientVersion": "0.1.0",
            "manufacturer": "Apple",
            "model": "Mac16,1",
        ])
    }
}
