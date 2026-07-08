import Foundation
import Testing
@testable import ABSKit
import ABSKitTestSupport

@Suite struct ABSClientTests {
    let base = URL(string: "http://abs.test:13378")!

    private func makeSUT() async throws -> (ABSClient, MockTransport, InMemoryTokenStore) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        return (ABSClient(baseURL: base, transport: transport, auth: auth), transport, store)
    }

    @Test func librariesSendsBearerAndDecodes() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"libraries":[{"id":"lib_1","name":"Books","mediaType":"book"}]}"#)
        let libs = try await client.libraries()
        #expect(libs.map { $0.id } == ["lib_1"])
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/libraries")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer acc1")
    }

    @Test func itemsBuildsPagedMinifiedQuery() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"results":[],"total":0,"limit":50,"page":2}"#)
        _ = try await client.items(libraryID: "lib_1", limit: 50, page: 2)
        let url = await transport.recorded.first?.url
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        #expect(comps.path == "/api/libraries/lib_1/items")
        let q: [String: String] = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(q == ["limit": "50", "page": "2", "minified": "1",
                      "sort": "media.metadata.title", "desc": "0"])
    }

    @Test func itemsThreadsSortDescAndFilter() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"results":[],"total":0,"limit":50,"page":0}"#)
        _ = try await client.items(libraryID: "lib_1", limit: 50, page: 0,
                                   sort: "media.metadata.authorName", desc: true,
                                   filter: "authors.U3VuIFR6dQ")
        let url = await transport.recorded.first?.url
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let q: [String: String] = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(q == ["limit": "50", "page": "0", "minified": "1",
                      "sort": "media.metadata.authorName", "desc": "1", "filter": "authors.U3VuIFR6dQ"])
    }

    @Test func retriesOnceAfter401ThenSucceeds() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 401, json: #"{"error":"Unauthorized"}"#)                        // original call
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"r","accessToken":"acc2","refreshToken":"ref2"}}"#) // refresh
        await transport.enqueue(status: 200, json: #"{"libraries":[]}"#)                                  // retry
        _ = try await client.libraries()
        #expect(await transport.requestCount() == 3)
        let retry = await transport.recorded.last
        #expect(retry?.value(forHTTPHeaderField: "Authorization") == "Bearer acc2")
    }

    @Test func secondConsecutive401Propagates() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 401, json: "{}")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"r","accessToken":"acc2","refreshToken":"ref2"}}"#)
        await transport.enqueue(status: 401, json: "{}")
        await #expect(throws: ABSError.http(status: 401)) { _ = try await client.libraries() }
    }

    @Test func coverURLIsUnauthenticatedAndTimestamped() async throws {
        let (client, _, _) = try await makeSUT()
        let url = client.coverURL(itemID: "li_1", width: 400, updatedAt: 1751060000000 as Int?)
        #expect(url.absoluteString == "http://abs.test:13378/api/items/li_1/cover?width=400&ts=1751060000000")
    }

    // MARK: - Task 1: bookmarks

    @Test func createBookmarkPostsTimeAndTitleAndDecodesResult() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"libraryItemId":"li_1","time":142,"title":"Ch. 3","createdAt":1700000000000}"#)
        let bookmark = try await client.createBookmark(itemID: "li_1", time: 142, title: "Ch. 3")
        #expect(bookmark.libraryItemId == "li_1")
        #expect(bookmark.time == 142)
        #expect(bookmark.title == "Ch. 3")

        let req = await transport.recorded.first
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/me/item/li_1/bookmark")
        let body = try #require(req?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["time"] as? Int == 142)
        #expect(json?["title"] as? String == "Ch. 3")
    }

    @Test func updateBookmarkPatchesKeyedByTime() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"libraryItemId":"li_1","time":142,"title":"Renamed","createdAt":1700000000000}"#)
        let bookmark = try await client.updateBookmark(itemID: "li_1", time: 142, title: "Renamed")
        #expect(bookmark.title == "Renamed")

        let req = await transport.recorded.first
        #expect(req?.httpMethod == "PATCH")
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/me/item/li_1/bookmark")
        let body = try #require(req?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["time"] as? Int == 142)
        #expect(json?["title"] as? String == "Renamed")
    }

    @Test func deleteBookmarkSendsWholeTimeInPathWithoutTrailingZero() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        try await client.deleteBookmark(itemID: "li_1", time: 142)

        let req = await transport.recorded.first
        #expect(req?.httpMethod == "DELETE")
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/me/item/li_1/bookmark/142")
        #expect(req?.httpBody == nil)
    }

    /// Regression guard for the Int-truncation bug: a fractional `time` MUST keep its decimal in
    /// the DELETE path (`/bookmark/55.7`, not `/bookmark/55`) — the server 404s on a truncated
    /// key (verified live in `ContractTests.bookmarkFractionalTimeRoundTripsLive`).
    @Test func deleteBookmarkKeepsFractionalTimeInPath() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        try await client.deleteBookmark(itemID: "li_1", time: 55.7)

        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/me/item/li_1/bookmark/55.7")
    }

    @Test func createBookmarkSendsFractionalTimeInBody() async throws {
        let (client, transport, _) = try await makeSUT()
        await transport.enqueue(status: 200, json: #"{"libraryItemId":"li_1","time":55.7,"title":"Ch. 3","createdAt":1700000000000}"#)
        let bookmark = try await client.createBookmark(itemID: "li_1", time: 55.7, title: "Ch. 3")
        #expect(bookmark.time == 55.7)

        let body = try #require(await transport.recorded.first?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["time"] as? Double == 55.7)
    }
}
