import Testing
@testable import ABSKit

@Suite struct TokenStoreTests {
    @Test func roundTripsAndClears() async throws {
        let store = InMemoryTokenStore()
        #expect(await store.tokens(for: "c1") == nil)
        try await store.save(TokenPair(accessToken: "a1", refreshToken: "r1"), for: "c1")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "a1", refreshToken: "r1"))
        try await store.save(TokenPair(accessToken: "a2", refreshToken: "r2"), for: "c1")
        #expect(await store.tokens(for: "c1")?.accessToken == "a2")
        await store.clear(for: "c1")
        #expect(await store.tokens(for: "c1") == nil)
    }

    @Test func isolatesConnections() async throws {
        let store = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: "a", refreshToken: nil), for: "c1")
        #expect(await store.tokens(for: "c2") == nil)
    }

    @Test func protocolTypedSaveThrowsAndRoundTrips() async throws {
        let store: any TokenStore = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: "a", refreshToken: "r"), for: "c1")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "a", refreshToken: "r"))
    }
}
