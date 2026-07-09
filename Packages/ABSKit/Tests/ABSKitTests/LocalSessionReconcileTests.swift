import Foundation
import Testing
@testable import ABSKit
import ABSKitTestSupport

/// M2a Task 3: `fileDownloadURL`, `syncLocalSessions`/`LocalPlaybackSession`, and the
/// `progressReconcileView()` typed view over `me()`'s `mediaProgress[]`.
@Suite struct LocalSessionReconcileTests {
    let base = URL(string: "http://abs.test:13378")!

    private func makeSUT(accessToken: String = "acc1") async throws -> (ABSClient, MockTransport) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: accessToken, refreshToken: "ref1"), for: "c1")
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        return (ABSClient(baseURL: base, transport: transport, auth: auth), transport)
    }

    // MARK: - fileDownloadURL

    @Test func fileDownloadURLPutsTokenInQueryNotHeader() async throws {
        let (client, transport) = try await makeSUT()
        let url = try await client.fileDownloadURL(itemID: "li_1", ino: "42")
        #expect(url.absoluteString == "http://abs.test:13378/api/items/li_1/file/42/download?token=acc1")
        // A pure URL builder — no network round trip, no Bearer header anywhere.
        #expect(await transport.requestCount() == 0)
    }

    @Test func fileDownloadURLNeverBuildsTheZipEndpoint() async throws {
        let (client, _) = try await makeSUT()
        let url = try await client.fileDownloadURL(itemID: "li_1", ino: "42")
        #expect(!url.path.contains("/download/zip"))
        #expect(url.path == "/api/items/li_1/file/42/download")
    }

    @Test func fileDownloadURLPercentEncodesAReservedCharacterToken() async throws {
        // JWTs don't normally carry these characters, but the query-building must not silently
        // corrupt a token that does — round-trip it back out and confirm it matches exactly.
        let (client, _) = try await makeSUT(accessToken: "a&b=c d/e")
        let url = try await client.fileDownloadURL(itemID: "li_1", ino: "42")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.queryItems?.count == 1)
        #expect(comps.queryItems?.first?.name == "token")
        #expect(comps.queryItems?.first?.value == "a&b=c d/e")
        // The raw query string must actually be escaped (not a bare unescaped "&" splitting params).
        #expect(comps.percentEncodedQuery?.contains("token=a%26b") == true)
    }

    // MARK: - syncLocalSessions / LocalPlaybackSession

    private func makeSession(
        id: String = "sess-1", libraryItemId: String = "li_1", episodeId: String? = nil,
        deviceId: String = "dev-1", currentTime: Double = 42, timeListened: Double = 10,
        duration: Double = 100, startedAt: Int = 1_700_000_000_000, updatedAt: Int = 1_700_000_010_000
    ) -> LocalPlaybackSession {
        LocalPlaybackSession(
            id: id, libraryItemId: libraryItemId, episodeId: episodeId,
            mediaType: episodeId == nil ? "book" : "podcast",
            currentTime: currentTime, timeListened: timeListened, duration: duration,
            deviceInfo: DeviceInfo(deviceId: deviceId, clientVersion: "0.1.0", model: "test"),
            startedAt: startedAt, updatedAt: updatedAt)
    }

    @Test func localPlaybackSessionDefaultsPlayMethodToLocal() {
        let session = makeSession()
        #expect(session.playMethod == 3)
        #expect(session.playMethod == LocalPlaybackSession.playMethodLocal)
    }

    @Test func localPlaybackSessionGeneratesUniqueUUIDWhenIdOmitted() {
        let a = LocalPlaybackSession(libraryItemId: "li_1", mediaType: "book", currentTime: 0,
                                      timeListened: 0, duration: 100,
                                      deviceInfo: DeviceInfo(deviceId: "d", clientVersion: "1", model: "m"),
                                      startedAt: 0, updatedAt: 0)
        let b = LocalPlaybackSession(libraryItemId: "li_1", mediaType: "book", currentTime: 0,
                                      timeListened: 0, duration: 100,
                                      deviceInfo: DeviceInfo(deviceId: "d", clientVersion: "1", model: "m"),
                                      startedAt: 0, updatedAt: 0)
        #expect(!a.id.isEmpty)
        #expect(a.id != b.id)
        #expect(UUID(uuidString: a.id) != nil)
    }

    @Test func syncLocalSessionsPostsSessionsAndDeviceInfoBody() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"results":[]}"#)

        let book = makeSession(id: "sess-book", libraryItemId: "li_1", episodeId: nil, deviceId: "dev-1")
        let episode = makeSession(id: "sess-ep", libraryItemId: "li_2", episodeId: "ep_1", deviceId: "dev-1",
                                  currentTime: 12, timeListened: 5, duration: 300)
        try await client.syncLocalSessions([book, episode])

        let req = await transport.recorded.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/session/local-all")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer acc1")

        let body = try #require(req?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let deviceInfo = try #require(json["deviceInfo"] as? [String: Any])
        #expect(deviceInfo["deviceId"] as? String == "dev-1")

        let sessions = try #require(json["sessions"] as? [[String: Any]])
        #expect(sessions.count == 2)

        let bookJSON = try #require(sessions.first { $0["id"] as? String == "sess-book" })
        #expect(bookJSON["libraryItemId"] as? String == "li_1")
        #expect(bookJSON["episodeId"] == nil || bookJSON["episodeId"] is NSNull)
        #expect(bookJSON["mediaType"] as? String == "book")
        #expect(bookJSON["currentTime"] as? Double == 42)
        #expect(bookJSON["timeListening"] as? Double == 10, "server field name is timeListening, not timeListened")
        #expect(bookJSON["timeListened"] == nil, "must NOT send the sync/close-family key name")
        #expect(bookJSON["duration"] as? Double == 100)
        #expect(bookJSON["playMethod"] as? Int == 3)
        #expect(bookJSON["startedAt"] as? Int == 1_700_000_000_000)
        #expect(bookJSON["updatedAt"] as? Int == 1_700_000_010_000)
        #expect((bookJSON["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "dev-1")

        let episodeJSON = try #require(sessions.first { $0["id"] as? String == "sess-ep" })
        #expect(episodeJSON["episodeId"] as? String == "ep_1")
        #expect(episodeJSON["mediaType"] as? String == "podcast")
    }

    @Test func syncLocalSessionsUsesFirstSessionsDeviceInfoAsTheTopLevelOne() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"results":[]}"#)
        let first = makeSession(id: "s1", deviceId: "device-A")
        let second = makeSession(id: "s2", deviceId: "device-B")
        try await client.syncLocalSessions([first, second])

        let body = try #require(await transport.recorded.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "device-A")
    }

    @Test func syncLocalSessionsIsANoOpForAnEmptyBatch() async throws {
        let (client, transport) = try await makeSUT()
        let results = try await client.syncLocalSessions([])
        #expect(results.isEmpty)
        #expect(await transport.requestCount() == 0)
    }

    /// The server answers HTTP 200 even when INDIVIDUAL sessions are rejected — `syncLocalSessions`
    /// must decode and RETURN the per-session verdicts so Task 6 prunes only the successful ones
    /// (a rejected session's offline listen time must not be silently lost). Tolerant decode:
    /// `error` present on failures, absent on success; an unmodeled `progressSynced` is ignored.
    @Test func syncLocalSessionsReturnsMixedPerSessionResults() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"""
        {"results":[
          {"id":"sess-ok","success":true,"progressSynced":true},
          {"id":"sess-bad","success":false,"error":"Media item not found"}
        ]}
        """#)

        let ok = makeSession(id: "sess-ok", libraryItemId: "li_1")
        let bad = makeSession(id: "sess-bad", libraryItemId: "li_gone")
        let results = try await client.syncLocalSessions([ok, bad])

        #expect(results.count == 2)
        let okResult = try #require(results.first { $0.id == "sess-ok" })
        #expect(okResult.success == true)
        #expect(okResult.error == nil)

        let badResult = try #require(results.first { $0.id == "sess-bad" })
        #expect(badResult.success == false)
        #expect(badResult.error == "Media item not found")

        // What Task 6 will actually do: prune only the successes.
        let prunable = Set(results.filter(\.success).map(\.id))
        #expect(prunable == ["sess-ok"])
    }

    // MARK: - progressReconcileView()

    @Test func progressReconcileViewKeysByLibraryItemAndEpisode() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"""
        {"id":"u1","username":"root","mediaProgress":[
          {"libraryItemId":"li_1","episodeId":null,"currentTime":30,"duration":4000,"progress":0.0075,"isFinished":false,"lastUpdate":1700000000000},
          {"libraryItemId":"li_2","episodeId":"ep_1","currentTime":120,"duration":500,"progress":0.24,"isFinished":false,"lastUpdate":1700000005000}
        ]}
        """#)

        let view = try await client.progressReconcileView()
        let book = try #require(view.progress(itemID: "li_1"))
        #expect(book.currentTime == 30)
        #expect(book.lastUpdate == 1_700_000_000_000)

        let episode = try #require(view.progress(itemID: "li_2", episodeID: "ep_1"))
        #expect(episode.currentTime == 120)
        #expect(episode.lastUpdate == 1_700_000_005_000)

        #expect(view.progress(itemID: "li_2") == nil, "the book-only lookup must NOT match a different item's episode row")
        #expect(view.progress(itemID: "li_3") == nil)
    }

    /// The load-bearing normalization: `me()` reports a book's `episodeId` as `null` (→ `nil`), but
    /// `LibraryCache.CachedProgress.episodeID` is a non-optional `String` that stores `""` for a
    /// book. A Task-6 lookup keyed by that `""` MUST resolve to the book's `me()` entry — without
    /// `nil == "" ` normalization it never would (`Optional("") != Optional.none`) and
    /// last-write-wins would silently never fire for ANY book.
    @Test func progressReconcileViewTreatsEmptyEpisodeIDAsBookMatchingLibraryCacheConvention() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"""
        {"id":"u1","username":"root","mediaProgress":[
          {"libraryItemId":"li_1","episodeId":null,"currentTime":30,"duration":4000,"progress":0.0075,"isFinished":false,"lastUpdate":1700000000000}
        ]}
        """#)
        let view = try await client.progressReconcileView()

        // Looked up the way Task 6 will: with a CachedProgress.episodeID of "" for a book.
        let viaEmptyString = try #require(view.progress(itemID: "li_1", episodeID: ""))
        #expect(viaEmptyString.currentTime == 30)
        // nil and "" resolve to the SAME entry.
        #expect(view.progress(itemID: "li_1", episodeID: nil)?.lastUpdate == viaEmptyString.lastUpdate)
        #expect(view["li_1", ""]?.currentTime == 30, "subscript shares the same normalization")
    }

    @Test func progressReconcileViewCallsMeExactlyOnce() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"id":"u1","username":"root","mediaProgress":[]}"#)
        _ = try await client.progressReconcileView()
        #expect(await transport.requestCount() == 1)
    }
}
