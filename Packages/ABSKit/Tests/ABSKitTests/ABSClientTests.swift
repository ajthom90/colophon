import Foundation
import Testing
@testable import ABSKit

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
        #expect(q == ["limit": "50", "page": "2", "minified": "1", "sort": "media.metadata.title"])
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
}
