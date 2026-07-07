import Foundation

public actor AuthManager {
    private let baseURL: URL
    private let connectionID: String
    private let transport: Transport
    private let store: TokenStore
    private var inFlightRefresh: Task<String, Error>?

    /// Emits the latest access token after every successful login or refresh, so long-lived
    /// consumers (e.g. the playback session heartbeat) can pick up rotated tokens without
    /// polling the token store themselves. Single-consumer by design; buffers only the most
    /// recent value since only the current token is ever useful to a new subscriber.
    public let tokenUpdates: AsyncStream<String>
    private let tokenContinuation: AsyncStream<String>.Continuation

    public init(baseURL: URL, connectionID: String, transport: Transport, store: TokenStore) {
        self.baseURL = baseURL
        self.connectionID = connectionID
        self.transport = transport
        self.store = store
        (self.tokenUpdates, self.tokenContinuation) = AsyncStream.makeStream(
            of: String.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func login(username: String, password: String) async throws -> LoginResponse {
        let response = try await ABSAPI.send(
            ABSAPI.loginRequest(baseURL: baseURL, username: username, password: password),
            as: LoginResponse.self, via: transport)
        guard let access = response.user.accessToken else { throw ABSError.invalidResponse }
        try await store.save(TokenPair(accessToken: access, refreshToken: response.user.refreshToken),
                             for: connectionID)
        tokenContinuation.yield(access)
        return response
    }

    /// Stores the token pair from a completed OIDC exchange and yields the access token to
    /// `tokenUpdates`, mirroring `login(username:password:)` so downstream consumers can't tell the
    /// two sign-in paths apart.
    public func completeOIDC(loginResponse: LoginResponse) async throws {
        guard let access = loginResponse.user.accessToken else { throw ABSError.invalidResponse }
        try await store.save(TokenPair(accessToken: access, refreshToken: loginResponse.user.refreshToken),
                             for: connectionID)
        tokenContinuation.yield(access)
    }

    public func currentAccessToken() async throws -> String {
        guard let pair = await store.tokens(for: connectionID) else { throw ABSError.notAuthenticated }
        return pair.accessToken
    }

    public func refreshAfterAuthFailure(staleToken: String) async throws -> String {
        // Someone already refreshed while we were failing — use theirs.
        if let current = await store.tokens(for: connectionID), current.accessToken != staleToken {
            return current.accessToken
        }
        if let existing = inFlightRefresh { return try await existing.value }

        let task = Task<String, Error> { [baseURL, transport, store, connectionID, tokenContinuation] in
            guard let pair = await store.tokens(for: connectionID),
                  let refreshToken = pair.refreshToken else { throw ABSError.reauthRequired }
            var req = URLRequest(url: baseURL.appending(path: "auth/refresh"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
            do {
                let response = try await ABSAPI.send(req, as: LoginResponse.self, via: transport)
                guard let access = response.user.accessToken else { throw ABSError.invalidResponse }
                // Server rotates the refresh token; keep the old one only if none returned.
                let newPair = TokenPair(accessToken: access,
                                        refreshToken: response.user.refreshToken ?? refreshToken)
                try await store.save(newPair, for: connectionID)
                tokenContinuation.yield(access)
                return access
            } catch ABSError.http(status: 401) {
                await store.clear(for: connectionID)
                throw ABSError.reauthRequired
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    public func logout() async {
        if let pair = await store.tokens(for: connectionID), let refresh = pair.refreshToken {
            var req = URLRequest(url: baseURL.appending(path: "logout"))
            req.httpMethod = "POST"
            req.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            _ = try? await transport.send(req)
        }
        await store.clear(for: connectionID)
    }
}
