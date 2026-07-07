import Foundation
import CryptoKit

public enum OIDCError: Error, Equatable, LocalizedError {
    /// Step 1 (`GET /auth/openid`) did not return a redirect — the server refused to start the flow.
    case serverRejected(status: Int)
    /// The step-1 redirect carried no usable IdP authorize URL: either no `Location` header, or a
    /// `Location` whose query has no `state`. Either way there is no server-issued state to bind the
    /// callback to, so the flow cannot proceed safely.
    case missingAuthorizeURL
    /// The browser-returned callback's `state` did not equal the server-issued state — a possible
    /// CSRF/session-fixation attempt; the exchange is aborted.
    case stateMismatch
    /// The browser-returned callback URL had no `code` query parameter.
    case callbackMissingCode
    /// Step 3 (`GET /auth/openid/callback`) failed. A non-2xx status carries that status; a 2xx that
    /// decodes without an `accessToken` is reported as `exchangeFailed(status: 200)` since there is no
    /// dedicated "empty session" case (see OIDCFlow deviation note).
    case exchangeFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .serverRejected(let status): "The server wouldn't start single sign-on (HTTP \(status))."
        case .missingAuthorizeURL: "The server didn't return a valid sign-in address."
        case .stateMismatch: "The sign-in response didn't match this request. Please try again."
        case .callbackMissingCode: "Sign-in didn't return an authorization code."
        case .exchangeFailed(let status): "Couldn't complete sign-in (HTTP \(status))."
        }
    }
}

/// Browser-agnostic OIDC Authorization-Code-with-PKCE flow against an Audiobookshelf server.
///
/// The IdP interaction is an injected `browser` closure — `ASWebAuthenticationSession` in the app,
/// a scripted cookie-jar client in tests/contract runs — so the flow itself stays pure and testable.
///
/// A single no-redirect, dedicated-cookie-jar `Transport` is used for BOTH server hops (step 1
/// authorize capture and step 3 callback exchange). Reusing one session means the ABS session
/// cookie set on the step-1 302 is automatically presented on the step-3 callback GET — which the
/// Task 5 cookie spike found to be load-bearing.
public struct OIDCFlow: Sendable {
    private let serverURL: URL
    private let clientID: String
    private let scheme: String
    private let transport: Transport
    private let verifier: String

    /// - Parameters:
    ///   - transport: injected for tests; `nil` builds the dedicated no-redirect cookie-jar transport.
    ///   - verifier: injected for the PKCE known-vector test; `nil` generates a fresh 84-char hex verifier.
    public init(serverURL: URL, clientID: String = "Colophon", scheme: String = "colophon",
                transport: Transport? = nil, verifier: String? = nil) {
        self.serverURL = serverURL
        self.clientID = clientID
        self.scheme = scheme
        self.transport = transport ?? Self.makeCookieJarTransport()
        self.verifier = verifier ?? Self.makeVerifier()
    }

    /// Runs the full flow. `browser` receives the IdP authorize URL and must return the
    /// `colophon://oauth?code=...&state=...` callback URL.
    public func authenticate(browser: @Sendable (URL) async throws -> URL) async throws -> LoginResponse {
        // Step 1: kick off the flow; capture the server's 302 to the IdP (no redirect following).
        let challenge = Self.codeChallenge(for: verifier)
        var authorizeComponents = URLComponents(
            url: serverURL.appending(path: "auth/openid"), resolvingAgainstBaseURL: false)!
        authorizeComponents.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: "\(scheme)://oauth"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let step1 = try await transport.send(URLRequest(url: authorizeComponents.url!))
        guard (300..<400).contains(step1.statusCode) else {
            throw OIDCError.serverRejected(status: step1.statusCode)
        }
        guard let location = Self.header("Location", in: step1.headers),
              let authorizeURL = URL(string: location),
              let serverState = Self.queryValue("state", in: authorizeURL) else {
            throw OIDCError.missingAuthorizeURL
        }

        // Step 2: hand the IdP authorize URL to the browser; it returns the app-scheme callback.
        let callback = try await browser(authorizeURL)
        guard Self.queryValue("state", in: callback) == serverState else { throw OIDCError.stateMismatch }
        guard let code = Self.queryValue("code", in: callback) else { throw OIDCError.callbackMissingCode }

        // Step 3: exchange the code (carrying the PKCE verifier) over the same cookie-jar session.
        var callbackComponents = URLComponents(
            url: serverURL.appending(path: "auth/openid/callback"), resolvingAgainstBaseURL: false)!
        callbackComponents.queryItems = [
            .init(name: "state", value: serverState),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier),
        ]
        let step3 = try await transport.send(URLRequest(url: callbackComponents.url!))
        guard (200..<300).contains(step3.statusCode) else {
            throw OIDCError.exchangeFailed(status: step3.statusCode)
        }
        let response = try ABSAPI.decoder.decode(LoginResponse.self, from: step3.data)
        guard response.user.accessToken != nil else { throw OIDCError.exchangeFailed(status: step3.statusCode) }
        return response
    }

    // MARK: - PKCE

    /// 42 random bytes, hex-encoded → 84 characters. Matches the official Audiobookshelf app's
    /// verifier length so servers that validate it behave identically.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 42)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `base64url(SHA256(verifier))` with no padding. The digest is taken over the verifier STRING's
    /// UTF-8 bytes (the hex characters themselves), per RFC 7636 with the S256 method.
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Transport & header helpers

    private static func makeCookieJarTransport() -> URLSessionTransport {
        // `.ephemeral` gives an isolated in-memory cookie jar (distinct from `.shared`). The jar
        // rides along when `URLSessionTransport(followRedirects:false)` rebuilds the session from
        // this configuration, so both hops share it.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config)
        return URLSessionTransport(session: session, followRedirects: false)
    }

    /// HTTP header names are case-insensitive; the transport preserves whatever casing the server sent.
    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == name }?.value
    }
}
