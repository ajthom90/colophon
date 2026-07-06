import Foundation

/// One-time migration support for moving Keychain-stored tokens from a legacy lookup key
/// (the pre-M1a scheme keyed tokens by the server URL string) to a new key (the
/// `CachedConnection` UUID introduced in M1a). Lives in ABSKit (rather than the app target)
/// specifically so it can be exercised by an in-memory `TokenStore` in unit tests — the app
/// target has no test bundle of its own.
public enum TokenMigration {
    /// If `newKey` has no tokens yet and `legacyKey` does, moves them to `newKey` and clears
    /// `legacyKey`. No-ops if `newKey` already has tokens (already migrated, or a fresh login
    /// already happened) or if there's nothing under `legacyKey` to migrate.
    public static func migrateLegacyTokensIfNeeded(
        from legacyKey: String, to newKey: String, store: TokenStore
    ) async {
        guard await store.tokens(for: newKey) == nil,
              let legacy = await store.tokens(for: legacyKey) else { return }
        try? await store.save(legacy, for: newKey)
        await store.clear(for: legacyKey)
    }
}
