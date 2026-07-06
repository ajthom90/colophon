import Foundation
import Testing
@testable import ABSKit

@Suite struct AuthManagerTests {
    let base = URL(string: "http://abs.test:13378")!

    private func makeSUT() async -> (AuthManager, MockTransport, InMemoryTokenStore) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        return (auth, transport, store)
    }

    private let loginJSON = #"{"user":{"id":"u1","username":"root","accessToken":"acc1","refreshToken":"ref1"}}"#

    @Test func loginStoresTokenPair() async throws {
        let (auth, transport, store) = await makeSUT()
        await transport.enqueue(status: 200, json: loginJSON)
        _ = try await auth.login(username: "root", password: "pw")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "acc1", refreshToken: "ref1"))
        #expect(try await auth.currentAccessToken() == "acc1")
    }

    @Test func currentTokenThrowsWhenLoggedOut() async {
        let (auth, _, _) = await makeSUT()
        await #expect(throws: ABSError.notAuthenticated) { _ = try await auth.currentAccessToken() }
    }

    @Test func refreshSendsHeaderAndOverwritesRotatedPair() async throws {
        let (auth, transport, store) = await makeSUT()
        try await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"root","accessToken":"acc2","refreshToken":"ref2"}}"#)
        let newToken = try await auth.refreshAfterAuthFailure(staleToken: "acc1")
        #expect(newToken == "acc2")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "acc2", refreshToken: "ref2"))
        let req = await transport.recorded.last
        #expect(req?.url?.absoluteString == "http://abs.test:13378/auth/refresh")
        #expect(req?.value(forHTTPHeaderField: "x-refresh-token") == "ref1")
    }

    @Test func refreshKeepsOldRefreshTokenWhenResponseOmitsIt() async throws {
        let (auth, transport, store) = await makeSUT()
        try await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"root","accessToken":"acc2"}}"#)
        _ = try await auth.refreshAfterAuthFailure(staleToken: "acc1")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "acc2", refreshToken: "ref1"))
    }

    @Test func staleCallerGetsAlreadyRefreshedTokenWithoutSecondRequest() async throws {
        let (auth, transport, store) = await makeSUT()
        try await store.save(TokenPair(accessToken: "acc2", refreshToken: "ref2"), for: "c1")
        let token = try await auth.refreshAfterAuthFailure(staleToken: "acc1")  // caller holds old token
        #expect(token == "acc2")
        #expect(await transport.requestCount() == 0)
    }

    @Test func concurrentRefreshesCollapseToOneRequest() async throws {
        let (auth, transport, store) = await makeSUT()
        try await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"root","accessToken":"acc2","refreshToken":"ref2"}}"#)
        async let a = auth.refreshAfterAuthFailure(staleToken: "acc1")
        async let b = auth.refreshAfterAuthFailure(staleToken: "acc1")
        let (ta, tb) = try await (a, b)
        #expect(ta == "acc2" && tb == "acc2")
        #expect(await transport.requestCount() == 1)
    }

    @Test func refresh401ClearsTokensAndSignalsReauth() async throws {
        let (auth, transport, store) = await makeSUT()
        try await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 401, json: #"{"error":"Unauthorized"}"#)
        await #expect(throws: ABSError.reauthRequired) {
            _ = try await auth.refreshAfterAuthFailure(staleToken: "acc1")
        }
        #expect(await store.tokens(for: "c1") == nil)
    }
}
