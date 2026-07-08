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
