import Foundation
#if canImport(Security)
import Security
#endif

public struct TokenPair: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public init(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
    }
}

public protocol TokenStore: Sendable {
    func tokens(for connectionID: String) async -> TokenPair?
    func save(_ tokens: TokenPair, for connectionID: String) async
    func clear(for connectionID: String) async
}

public actor InMemoryTokenStore: TokenStore {
    private var storage: [String: TokenPair] = [:]
    public init() {}
    public func tokens(for connectionID: String) -> TokenPair? { storage[connectionID] }
    public func save(_ tokens: TokenPair, for connectionID: String) { storage[connectionID] = tokens }
    public func clear(for connectionID: String) { storage[connectionID] = nil }
}

/// Device-local by design: refresh tokens rotate on every use, so they must never
/// sync between devices (kSecAttrSynchronizable stays false).
public actor KeychainTokenStore: TokenStore {
    private let service = "com.ajthom90.colophon.tokens"
    public init() {}

    public func tokens(for connectionID: String) -> TokenPair? {
        var query = baseQuery(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TokenPair.self, from: data)
    }

    public func save(_ tokens: TokenPair, for connectionID: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        var query = baseQuery(connectionID)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attrs) { _, new in new }
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    public func clear(for connectionID: String) {
        SecItemDelete(baseQuery(connectionID) as CFDictionary)
    }

    private func baseQuery(_ connectionID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: connectionID]
    }
}
