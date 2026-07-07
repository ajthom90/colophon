import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]
    public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode; self.data = data; self.headers = headers
    }
}

public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: Transport {
    let session: URLSession
    public let followRedirects: Bool

    public init(session: URLSession = .shared, followRedirects: Bool = true) {
        self.followRedirects = followRedirects
        if followRedirects {
            self.session = session
        } else {
            let configuration = session.configuration
            self.session = URLSession(
                configuration: configuration,
                delegate: NoRedirectSessionDelegate(),
                delegateQueue: session.delegateQueue
            )
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ABSError.invalidResponse }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPResponse(statusCode: http.statusCode, data: data, headers: headers)
    }
}

/// Stops `URLSession` from automatically following HTTP redirects. Passing `nil` to the
/// completion handler makes the redirect response itself (headers, status, body) surface as
/// the task's result — callers that need the raw `Location`/`Set-Cookie` headers (e.g. an
/// OIDC authorization redirect) get them instead of the followed destination's response.
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum ABSError: Error, Equatable {
    case http(status: Int)
    case notAuthenticated
    case reauthRequired
    case invalidResponse
    case serverTooOld(found: String)
}

extension ABSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status): "The server returned an error (HTTP \(status))."
        case .notAuthenticated: "You're not signed in to this server."
        case .reauthRequired: "Your session expired. Please sign in again."
        case .invalidResponse: "The server sent an unexpected response."
        case .serverTooOld(let found):
            "This server runs Audiobookshelf \(found). Colophon requires 2.26.0 or newer."
        }
    }
}

public enum ABSAPI {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    public static func statusRequest(baseURL: URL) -> URLRequest {
        URLRequest(url: baseURL.appending(path: "status"))
    }

    public static func loginRequest(baseURL: URL, username: String, password: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: "login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-return-tokens")
        req.httpBody = try? encoder.encode(["username": username, "password": password])
        return req
    }

    public static func send<T: Decodable>(_ request: URLRequest, as type: T.Type, via transport: Transport) async throws -> T {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode) }
        return try decoder.decode(T.self, from: response.data)
    }

    public static func sendExpectingSuccess(_ request: URLRequest, via transport: Transport) async throws {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode) }
    }
}
