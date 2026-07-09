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

    /// Raw `/api/me` progress lookup keyed by `(libraryItemId, episodeId)`, surfacing the
    /// mediaProgress record's own server-assigned `id` — needed for `DELETE /api/me/progress/:id`
    /// reset cleanup, but not otherwise modeled on the public `MediaProgressEntry` (Task 3 scope
    /// is `fileDownloadURL`/`syncLocalSessions`/`progressReconcileView`, not a progress-deletion
    /// API), so this reaches into `ABSClient`'s internal `get`/`authorizedData` via `@testable`.
    private func rawMediaProgress(_ client: ABSClient, libraryItemId: String, episodeId: String?) async throws -> (id: String, currentTime: Double?)? {
        let data = try await client.authorizedData(client.get("api/me"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let progress = object["mediaProgress"] as? [[String: Any]] else { return nil }
        guard let match = progress.first(where: {
            ($0["libraryItemId"] as? String) == libraryItemId && ($0["episodeId"] as? String) == episodeId
        }), let id = match["id"] as? String else { return nil }
        return (id: id, currentTime: match["currentTime"] as? Double)
    }

    private func deleteMediaProgress(_ client: ABSClient, id: String) async throws {
        var req = URLRequest(url: client.baseURL.appending(path: "api/me/progress/\(id)"))
        req.httpMethod = "DELETE"
        _ = try await client.authorizedData(req)
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

    // MARK: - M2a Task 3: file-download URL + local-session batch reconcile

    /// Live-verifies `fileDownloadURL`: gets a real track's `ino` from a `/play` session's
    /// `audioTracks[].contentUrl` (`/api/items/:id/file/:ino` — the SAME `:ino` value the
    /// download route keys on, just without the `/download` suffix), builds the download URL,
    /// and confirms it serves real audio bytes over a request that carries NO Authorization
    /// header at all — proving the query `token` alone is what authorizes it (this is exactly
    /// how Task 4's background `URLSession` will call it: no shared session, no Bearer header).
    /// Closes the session immediately after (no sync) so the dev seed is left exactly as found.
    @Test func fileDownloadURLServesAudioBytesLive() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let bookLib = try #require(libs.first { $0.mediaType == "book" })
        let page = try await client.items(libraryID: bookLib.id, limit: 1, page: 0)
        let itemID = try #require(page.results.first?.id)

        // A DISTINCT deviceId from `fullPlaybackLifecycle`'s "contract-test": Swift Testing runs
        // suite tests concurrently, and ABS evicts/closes a device's prior open session when the
        // SAME deviceId starts a new one — reusing that id here intermittently 404'd the other
        // test's later sync/close calls (observed live this task).
        let device = DeviceInfo(deviceId: "contract-test-file-download", clientVersion: "0.1.0", model: "test")
        let envelope = try await client.startPlayback(itemID: itemID, deviceInfo: device)
        let track = try #require(envelope.session.audioTracks.first)
        let ino = try #require(track.contentUrl?.split(separator: "/").last).description

        let url = try await client.fileDownloadURL(itemID: itemID, ino: ino)
        #expect(url.path == "/api/items/\(itemID)/file/\(ino)/download")
        #expect(url.query?.hasPrefix("token=") == true)

        let response = try await transport.send(URLRequest(url: url))   // no Authorization header
        #expect(response.statusCode == 200, "expected the query token alone to authorize the download")
        #expect(response.data.count > 1_000, "expected real audio bytes, not an error body")
        let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value
        #expect(contentType?.hasPrefix("audio/") == true, "expected an audio content-type, got \(contentType ?? "nil")")

        try await client.closeSession(id: envelope.session.id, currentTime: envelope.session.startTime,
                                      timeListened: 0, duration: envelope.session.duration)
    }

    /// Live-verifies `syncLocalSessions`: POSTs a `local-all` batch for a throwaway offline
    /// session against a real seeded book, confirms `/api/me` reflects the synced `currentTime`,
    /// then RESETS by deleting that mediaProgress record (`DELETE /api/me/progress/:id`) so the
    /// seed ends up clean — no lingering test-authored progress. `updatedAt` is real wall-clock
    /// "now" (not a fixed past value) because the server's reconcile is itself last-write-wins
    /// (`PlaybackSessionManager.syncLocalSession`: it SKIPS the progress update if the existing
    /// record's `updatedAt` is already newer) — this book already carries progress from earlier
    /// contract runs, so only a genuinely newer timestamp is guaranteed to win and apply.
    @Test func syncLocalSessionsBatchReconcilesLiveThenResets() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let bookLib = try #require(libs.first { $0.mediaType == "book" })
        let page = try await client.items(libraryID: bookLib.id, limit: 1, page: 0)
        let itemID = try #require(page.results.first?.id)
        let detail = try await client.item(id: itemID)
        let duration = try #require(detail.media.duration)
        let currentTime = min(500, duration / 2)

        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        let session = LocalPlaybackSession(
            libraryItemId: itemID, mediaType: "book",
            currentTime: currentTime, timeListened: 60, duration: duration,
            deviceInfo: DeviceInfo(deviceId: "contract-test-local-all", clientVersion: "0.1.0", model: "test"),
            startedAt: nowMillis - 60_000, updatedAt: nowMillis)

        let results = try await client.syncLocalSessions([session])
        #expect(results.count == 1, "server must return one result per posted session")
        let result = try #require(results.first)
        #expect(result.id == session.id, "the server echoes back the posted session id")
        #expect(result.success == true, "a valid seeded item must sync successfully")
        #expect(result.error == nil)

        let synced = try #require(await rawMediaProgress(client, libraryItemId: itemID, episodeId: nil),
                                  "expected /api/me to carry progress for this item after the batch sync")
        #expect(synced.currentTime == currentTime)

        // Reset: delete the progress record entirely so the seed is left clean.
        try await deleteMediaProgress(client, id: synced.id)
        let cleaned = try await rawMediaProgress(client, libraryItemId: itemID, episodeId: nil)
        #expect(cleaned == nil, "progress must be gone after reset")
    }
}
