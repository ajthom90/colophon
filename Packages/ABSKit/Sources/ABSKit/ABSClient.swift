import Foundation

public final class ABSClient: Sendable {
    let baseURL: URL
    let transport: Transport
    let auth: AuthManager

    public init(baseURL: URL, transport: Transport, auth: AuthManager) {
        self.baseURL = baseURL; self.transport = transport; self.auth = auth
    }

    public static func status(baseURL: URL, transport: Transport) async throws -> ServerStatus {
        try await ABSAPI.send(ABSAPI.statusRequest(baseURL: baseURL), as: ServerStatus.self, via: transport)
    }

    public func libraries() async throws -> [Library] {
        try await authorizedSend(get("api/libraries"), as: LibrariesResponse.self).libraries
    }

    /// Probes the stored credentials against `POST /api/authorize` (Bearer). Returns normally
    /// when the token is valid — or was silently refreshed by `authorizedData`'s 401 machinery.
    /// A 401 whose refresh also fails surfaces as `ABSError.reauthRequired`; a dead host throws
    /// the transport's underlying error. Used by `AppState.activateConnection` to decide between
    /// online mode, a "needs sign-in" re-auth prompt, and staying in cached-only offline mode.
    public func authorize() async throws {
        var req = get("api/authorize")
        req.httpMethod = "POST"
        _ = try await authorizedData(req)
    }

    public func items(libraryID: String, limit: Int, page: Int) async throws -> ItemsPage {
        var comps = URLComponents(url: baseURL.appending(path: "api/libraries/\(libraryID)/items"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "limit", value: String(limit)),
            .init(name: "page", value: String(page)),
            .init(name: "minified", value: "1"),
            .init(name: "sort", value: "media.metadata.title"),
        ]
        return try await authorizedSend(URLRequest(url: comps.url!), as: ItemsPage.self)
    }

    /// Fetches one item's expanded detail (`?expanded=1` — full metadata incl. the
    /// server-computed `authorName`, and, once modeled, chapters). Used by `AppState`'s
    /// per-item socket patch (`apply(.itemChanged)`/`apply(.itemsChanged)`, Task 3) in place of
    /// a coarse full-library re-page, and by M1c-b's item-detail view.
    public func item(id: String) async throws -> LibraryItemDetail {
        var comps = URLComponents(url: baseURL.appending(path: "api/items/\(id)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "expanded", value: "1")]
        return try await authorizedSend(URLRequest(url: comps.url!), as: LibraryItemDetail.self)
    }

    public func coverURL(itemID: String, width: Int, updatedAt: Int?) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: "api/items/\(itemID)/cover"),
                                  resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [.init(name: "width", value: String(width))]
        if let updatedAt { query.append(.init(name: "ts", value: String(updatedAt))) }
        comps.queryItems = query
        return comps.url!
    }

    // MARK: - Internals

    func get(_ path: String) -> URLRequest { URLRequest(url: baseURL.appending(path: path)) }

    func authorizedSend<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await authorizedData(request)
        return try ABSAPI.decoder.decode(T.self, from: data)
    }

    func authorizedData(_ request: URLRequest) async throws -> Data {
        let token = try await auth.currentAccessToken()
        var authed = request
        authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(authed)
        if response.statusCode == 401 {
            let fresh = try await auth.refreshAfterAuthFailure(staleToken: token)
            var retry = request
            retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            let second = try await transport.send(retry)
            guard (200..<300).contains(second.statusCode) else { throw ABSError.http(status: second.statusCode) }
            return second.data
        }
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode) }
        return response.data
    }
}

/// A `startPlayback` response paired with the raw bytes the server returned. The raw bytes
/// are the exact shape `api/session/local` expects for 404-recovery upserts — re-encoding the
/// decoded `PlaybackSession` would drop server fields we don't model and risk a shape mismatch.
public struct PlaybackSessionEnvelope: Sendable {
    public let session: PlaybackSession
    public let rawData: Data
    public init(session: PlaybackSession, rawData: Data) { self.session = session; self.rawData = rawData }
}

extension ABSClient {
    /// MIME types AVPlayer direct-plays; anything else transcodes to HLS server-side.
    static let supportedMimeTypes = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-m4b"]

    public func startPlayback(itemID: String, deviceInfo: DeviceInfo) async throws -> PlaybackSessionEnvelope {
        struct PlayRequest: Encodable {
            let deviceInfo: DeviceInfo
            let mediaPlayer: String
            let supportedMimeTypes: [String]
            let forceDirectPlay: Bool
            let forceTranscode: Bool
        }
        var req = URLRequest(url: baseURL.appending(path: "api/items/\(itemID)/play"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(PlayRequest(
            deviceInfo: deviceInfo, mediaPlayer: "AVPlayer",
            supportedMimeTypes: Self.supportedMimeTypes,
            forceDirectPlay: false, forceTranscode: false))
        let data = try await authorizedData(req)
        let session = try ABSAPI.decoder.decode(PlaybackSession.self, from: data)
        return PlaybackSessionEnvelope(session: session, rawData: data)
    }

    /// Recovery path when the server has restarted and lost the in-memory session (sync/close
    /// then 404): resubmits the original `startPlayback` JSON with progress fields overwritten,
    /// which the server accepts as a local-progress upsert independent of session lifecycle.
    public func postLocalSession(rawData: Data, currentTime: Double, totalListened: Double) async throws {
        guard var object = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw ABSError.invalidResponse
        }
        object["currentTime"] = currentTime
        object["timeListening"] = totalListened
        object["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
        var req = URLRequest(url: baseURL.appending(path: "api/session/local"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: object)
        _ = try await authorizedData(req)
    }

    public func syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/sync",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    public func closeSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/close",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    /// Verified against a live ABS 2.35.1 server (see ContractTests.fullPlaybackLifecycle):
    /// pass the audio track's own 1-indexed `AudioTrack.index` value directly as `trackIndex`,
    /// not its position in the `audioTracks` array — the server resolves the URL by that field
    /// and serves the correct bytes. Range requests are honored (206 + exact byte count).
    public func publicTrackURL(sessionID: String, trackIndex: Int) -> URL {
        baseURL.appending(path: "public/session/\(sessionID)/track/\(trackIndex)")
    }

    private func postSessionPayload(path: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(
            ["currentTime": currentTime, "timeListened": timeListened, "duration": duration])
        _ = try await authorizedData(req)
    }
}
