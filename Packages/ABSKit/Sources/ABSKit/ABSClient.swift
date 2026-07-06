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

extension ABSClient {
    /// MIME types AVPlayer direct-plays; anything else transcodes to HLS server-side.
    static let supportedMimeTypes = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-m4b"]

    public func startPlayback(itemID: String, deviceInfo: DeviceInfo) async throws -> PlaybackSession {
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
        return try await authorizedSend(req, as: PlaybackSession.self)
    }

    public func syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/sync",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    public func closeSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/close",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

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
