import Testing
@testable import ABSKit

@Suite struct TokenStoreTests {
    @Test func roundTripsAndClears() async {
        let store = InMemoryTokenStore()
        #expect(await store.tokens(for: "c1") == nil)
        await store.save(TokenPair(accessToken: "a1", refreshToken: "r1"), for: "c1")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "a1", refreshToken: "r1"))
        await store.save(TokenPair(accessToken: "a2", refreshToken: "r2"), for: "c1")
        #expect(await store.tokens(for: "c1")?.accessToken == "a2")
        await store.clear(for: "c1")
        #expect(await store.tokens(for: "c1") == nil)
    }

    @Test func isolatesConnections() async {
        let store = InMemoryTokenStore()
        await store.save(TokenPair(accessToken: "a", refreshToken: nil), for: "c1")
        #expect(await store.tokens(for: "c2") == nil)
    }
}
