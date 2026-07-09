import Foundation
import Testing
@testable import ABSKit

/// Run with: ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests
/// Requires `make server-up && make seed` first.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] != nil))
struct ContractTests {
    let base = URL(string: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] ?? "http://invalid")!
    let transport = URLSessionTransport()

    private func loggedInClient() async throws -> ABSClient {
        let store = InMemoryTokenStore()
        let auth = AuthManager(baseURL: base, connectionID: "contract", transport: transport, store: store)
        _ = try await auth.login(username: "root", password: "colophon-dev")
        return ABSClient(baseURL: base, transport: transport, auth: auth)
    }

    @Test func statusReportsSupportedVersion() async throws {
        let status = try await ABSClient.status(baseURL: base, transport: transport)
        #expect(status.isInit == true)
        #expect(status.serverVersion?.hasPrefix("2.3") == true)
    }

    @Test func fullPlaybackLifecycle() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        #expect(!libs.isEmpty)
        let page = try await client.items(libraryID: libs[0].id, limit: 10, page: 0)
        #expect(page.total >= 1)

        let device = DeviceInfo(deviceId: "contract-test", clientVersion: "0.1.0", model: "test")
        let envelope = try await client.startPlayback(itemID: page.results[0].id, deviceInfo: device)
        let session = envelope.session
        #expect(!session.audioTracks.isEmpty)
        #expect(session.playMethod == 0)  // seeded mp3s must direct-play

        // Empirical: public track URL serves audio for the track's own index value.
        let track = session.audioTracks[0]
        let trackURL = client.publicTrackURL(sessionID: session.id, trackIndex: track.index)
        var head = URLRequest(url: trackURL)
        head.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let ranged = try await transport.send(head)
        #expect(ranged.statusCode == 206, "expected partial content; got \(ranged.statusCode) — check index base or Range support")
        #expect(ranged.data.count == 1024)

        try await client.syncSession(id: session.id, currentTime: 30, timeListened: 15, duration: session.duration)
        try await client.closeSession(id: session.id, currentTime: 30, timeListened: 0, duration: session.duration)

        // Closed sessions are gone from server memory: sync must now 404.
        await #expect(throws: ABSError.http(status: 404)) {
            try await client.syncSession(id: session.id, currentTime: 31, timeListened: 1, duration: session.duration)
        }
    }

    @Test func coverEndpointIsUnauthenticatedAndServesImage() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let page = try await client.items(libraryID: libs[0].id, limit: 1, page: 0)
        let url = client.coverURL(itemID: page.results[0].id, width: 200, updatedAt: page.results[0].updatedAt)
        let unauthed = try await transport.send(URLRequest(url: url))   // no Authorization header
        #expect(unauthed.statusCode == 200, "seed must provide cover.jpg — re-run make seed after wiping devserver/data")
        #expect(unauthed.data.count > 1_000)                            // a real image, not an error body
    }

    // MARK: - Task 5: browse, search, and me endpoints

    @Test func personalizedShelvesReturnsSeededShelves() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let shelves = try await client.personalizedShelves(libraryID: libs[0].id, limit: 10)
        #expect(!shelves.isEmpty)
        #expect(shelves.contains { $0.id == "continue-listening" })
    }

    @Test func filterDataReflectsSeededLibrary() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let filterData = try await client.filterData(libraryID: libs[0].id)
        #expect(filterData.bookCount == 1)
        #expect(filterData.authors.map(\.name) == ["Sun Tzu"])
    }

    @Test func authorsIncludesSeededAuthor() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let authors = try await client.authors(libraryID: libs[0].id)
        #expect(authors.contains { $0.name == "Sun Tzu" })
    }

    @Test func searchMatchBucketBehaviorIsLive() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let byTitle = try await client.searchLibrary(libraryID: libs[0].id, query: "art", limit: 12)
        #expect(byTitle.book?.isEmpty == false)

        let byAuthor = try await client.searchLibrary(libraryID: libs[0].id, query: "sun", limit: 12)
        #expect(byAuthor.book?.isEmpty == true, "book bucket must NOT match author name")
        #expect(byAuthor.authors?.isEmpty == false, "author-only match must surface in the authors bucket")
    }

    @Test func meReturnsMediaProgress() async throws {
        let client = try await loggedInClient()
        let me = try await client.me()
        #expect(me.username == "root")
        #expect(me.mediaProgress?.isEmpty == false)
    }

    // MARK: - Task 1: bookmark create/update/delete round trip

    /// Live create→patch→delete against the real server, then confirms via `/api/me` that the
    /// bookmark is gone — leaves the dev seed exactly as it found it (no bookmarks).
    @Test func bookmarkCreateUpdateDeleteRoundTripsLive() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let page = try await client.items(libraryID: libs[0].id, limit: 1, page: 0)
        let itemID = page.results[0].id

        let created = try await client.createBookmark(itemID: itemID, time: 77, title: "Contract test")
        #expect(created.libraryItemId == itemID)
        #expect(created.time == 77)
        #expect(created.title == "Contract test")

        let updated = try await client.updateBookmark(itemID: itemID, time: 77, title: "Contract test renamed")
        #expect(updated.title == "Contract test renamed")

        let meBeforeDelete = try await client.me()
        #expect(meBeforeDelete.bookmarks?.contains { $0.libraryItemId == itemID && $0.time == 77 } == true)

        try await client.deleteBookmark(itemID: itemID, time: 77)

        let meAfterDelete = try await client.me()
        #expect(meAfterDelete.bookmarks?.contains { $0.libraryItemId == itemID && $0.time == 77 } != true)
    }

    /// Locks the Fix-round-2 truncation fix: a bookmark created at a FRACTIONAL time (like a real
    /// playback position) must be PATCH-able and DELETE-able at that exact value. Before the fix,
    /// the `time: Int` write methods truncated `55.7`→`55`, so PATCH `{time:55}` and
    /// `DELETE /bookmark/55` both 404'd against the `55.7` bookmark (verified live). Leaves the
    /// dev seed clean.
    @Test func bookmarkFractionalTimeRoundTripsLive() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let page = try await client.items(libraryID: libs[0].id, limit: 1, page: 0)
        let itemID = page.results[0].id

        let created = try await client.createBookmark(itemID: itemID, time: 55.7, title: "Fractional")
        #expect(created.time == 55.7)

        let updated = try await client.updateBookmark(itemID: itemID, time: 55.7, title: "Fractional renamed")
        #expect(updated.time == 55.7)
        #expect(updated.title == "Fractional renamed")

        let meBeforeDelete = try await client.me()
        #expect(meBeforeDelete.bookmarks?.contains { $0.libraryItemId == itemID && $0.time == 55.7 } == true)

        try await client.deleteBookmark(itemID: itemID, time: 55.7)

        let meAfterDelete = try await client.me()
        #expect(meAfterDelete.bookmarks?.contains { $0.libraryItemId == itemID && $0.time == 55.7 } != true)
    }

    // MARK: - M1c-c Task 1: seeded podcast library

    /// Live-verifies the seeded "Colophon Test Podcast": the podcast library exposes an
    /// episode-typed personalized shelf (`newest-episodes`, present without progress), and search
    /// populates BOTH podcast-only buckets (`q=on` matches the podcast title and an episode title).
    /// Read-only — creates no transient state, so the seed stays clean.
    @Test func podcastLibraryExposesEpisodeShelvesAndSearchBuckets() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let podcastLib = try #require(libs.first { $0.mediaType == "podcast" },
                                      "seed must create a podcast library — run make seed")

        let shelves = try await client.personalizedShelves(libraryID: podcastLib.id, limit: 10)
        #expect(shelves.contains { $0.type == "episode" }, "podcast library must expose episode-typed shelves")
        let newest = try #require(shelves.first { $0.id == "newest-episodes" })
        guard case .episode = newest.entities.first else {
            Issue.record("newest-episodes must contain episode shelf entities")
            return
        }

        let results = try await client.searchLibrary(libraryID: podcastLib.id, query: "on", limit: 10)
        #expect(results.podcast?.isEmpty == false, "q=on must match the podcast title")
        #expect(results.episodes?.isEmpty == false, "q=on must match an episode title")
        #expect(results.episodes?.first?.libraryItem.recentEpisode?.title != nil,
                "episode hit must carry the matched episode in libraryItem.recentEpisode")
    }

    // MARK: - M1c-c Task 2: podcast item + episode playback

    /// Live-verifies `podcastItem(id:)` against the seeded "Colophon Test Podcast" (podcast
    /// metadata + both episodes), then plays an episode via `playEpisode` and immediately CLOSES
    /// the session so the dev seed is left exactly as it found it (no lingering session/progress).
    @Test func podcastItemAndEpisodePlaybackRoundTripLive() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let podcastLib = try #require(libs.first { $0.mediaType == "podcast" },
                                      "seed must create a podcast library — run make seed")
        let podcastPage = try await client.items(libraryID: podcastLib.id, limit: 10, page: 0)
        let podcastItemID = try #require(podcastPage.results.first?.id)

        let detail = try await client.podcastItem(id: podcastItemID)
        #expect(detail.id == podcastItemID)
        #expect(detail.media.metadata.title == "Colophon Test Podcast")
        #expect(detail.media.episodes.count == 2)
        let episode = try #require(detail.media.episodes.first)

        let device = DeviceInfo(deviceId: "contract-test", clientVersion: "0.1.0", model: "test")
        let envelope = try await client.playEpisode(itemID: podcastItemID, episodeId: episode.id, deviceInfo: device)
        let session = envelope.session
        #expect(session.episodeId == episode.id)
        #expect(session.libraryItemId == podcastItemID)
        #expect(!session.audioTracks.isEmpty)

        // Leave the seed clean: close the session immediately (no sync — avoid leaving progress).
        try await client.closeSession(id: session.id, currentTime: session.startTime,
                                      timeListened: 0, duration: session.duration)
    }
}
