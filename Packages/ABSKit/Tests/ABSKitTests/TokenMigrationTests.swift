import Testing
@testable import ABSKit

/// Reads/clears delegate to a backing InMemoryTokenStore; `save` always throws — models a
/// Keychain write failure mid-migration.
private actor ThrowingSaveTokenStore: TokenStore {
    let backing = InMemoryTokenStore()
    func tokens(for connectionID: String) async -> TokenPair? {
        await backing.tokens(for: connectionID)
    }
    func save(_ tokens: TokenPair, for connectionID: String) async throws {
        throw TokenStoreError.keychainFailure(-1)
    }
    func clear(for connectionID: String) async {
        await backing.clear(for: connectionID)
    }
}

@Suite struct TokenMigrationTests {
    @Test func movesLegacyTokensToNewKeyAndClearsLegacy() async throws {
        let store = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: "a1", refreshToken: "r1"), for: "http://legacy.example:13378")
        await TokenMigration.migrateLegacyTokensIfNeeded(
            from: "http://legacy.example:13378", to: "NEW-UUID", store: store)
        #expect(await store.tokens(for: "NEW-UUID") == TokenPair(accessToken: "a1", refreshToken: "r1"))
        #expect(await store.tokens(for: "http://legacy.example:13378") == nil)
    }

    @Test func noOpWhenNewKeyAlreadyHasTokens() async throws {
        let store = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: "legacy", refreshToken: "legacy-r"), for: "legacy-key")
        try await store.save(TokenPair(accessToken: "fresh", refreshToken: "fresh-r"), for: "NEW-UUID")
        await TokenMigration.migrateLegacyTokensIfNeeded(from: "legacy-key", to: "NEW-UUID", store: store)
        // Fresh login tokens must not be clobbered by a stale legacy entry.
        #expect(await store.tokens(for: "NEW-UUID") == TokenPair(accessToken: "fresh", refreshToken: "fresh-r"))
        // And the legacy entry is left untouched since no migration happened.
        #expect(await store.tokens(for: "legacy-key") == TokenPair(accessToken: "legacy", refreshToken: "legacy-r"))
    }

    @Test func noOpWhenNoLegacyTokensExist() async throws {
        let store = InMemoryTokenStore()
        await TokenMigration.migrateLegacyTokensIfNeeded(from: "legacy-key", to: "NEW-UUID", store: store)
        #expect(await store.tokens(for: "NEW-UUID") == nil)
        #expect(await store.tokens(for: "legacy-key") == nil)
    }

    @Test func failedSavePreservesLegacyTokens() async throws {
        let store = ThrowingSaveTokenStore()
        let legacy = TokenPair(accessToken: "a1", refreshToken: "r1")
        try await store.backing.save(legacy, for: "legacy-key")
        await TokenMigration.migrateLegacyTokensIfNeeded(from: "legacy-key", to: "NEW-UUID", store: store)
        // The failed save must not destroy the sole remaining copy of the tokens...
        #expect(await store.tokens(for: "legacy-key") == legacy)
        // ...and nothing landed under the new key.
        #expect(await store.tokens(for: "NEW-UUID") == nil)
    }
}
