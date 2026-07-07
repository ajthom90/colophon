import Foundation
import Testing
@testable import ABSKit

/// Live OIDC code-flow contract test against the dev stack (Dex + ABS).
///
/// Gated two ways, matching the plan:
///  1. Suite-level: only enabled when `ABS_CONTRACT_URL` is set. In CI / the current
///     environment (Task 5's Dex stack not yet landed) the var is unset, so the suite
///     SKIPS cleanly and never touches the network.
///  2. Runtime: even when enabled, the single test first checks `GET /status` and no-ops
///     unless `openid` is an active auth method — so pointing `ABS_CONTRACT_URL` at a
///     password-only server doesn't spuriously fail.
///
/// Run (after Task 5 lands `make server-up && make seed` with Dex active):
///   ABS_CONTRACT_URL=http://localhost:13378 swift test --filter OIDCContractTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] != nil))
struct OIDCContractTests {
    let base = URL(string: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] ?? "http://invalid")!

    @Test func fullOIDCCodeFlowYieldsSession() async throws {
        // Runtime gate: only meaningful once the dev stack advertises openid (Task 5's Dex seed).
        let status = try await ABSClient.status(baseURL: base, transport: URLSessionTransport())
        guard status.authMethods?.contains("openid") == true else { return }

        let flow = OIDCFlow(serverURL: base)
        let response = try await flow.authenticate(browser: Self.scriptedDexBrowser)
        #expect(response.user.accessToken?.isEmpty == false)
    }

    /// A curl-equivalent "browser": walks the Dex hosted-login form headlessly using its own
    /// cookie jar, per the Task 5 spike transcript. Receives the ABS-issued authorize URL and
    /// must return the `colophon://oauth?code=...&state=...` callback URL.
    ///
    /// NOTE: unverified until Task 5's Dex stack lands — the selectors/redirect chain below are
    /// derived from the plan's spike description and will be validated during that task's live run.
    @Sendable static func scriptedDexBrowser(_ authorizeURL: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: config)

        // 1. GET the Dex authorize page (follows Dex's internal redirect to the login form).
        let (page, _) = try await session.data(from: authorizeURL)
        let html = String(decoding: page, as: UTF8.self)

        // 2. Extract the login form action (Dex renders `<form ... action="/dex/auth/local/login?...">`).
        guard let action = firstMatch(in: html, pattern: #"action="([^"]*/login[^"]*)""#),
              let formURL = URL(string: action, relativeTo: authorizeURL) else {
            throw OIDCError.missingAuthorizeURL
        }

        // 3. POST the static test-user credentials.
        var post = URLRequest(url: formURL.absoluteURL)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [.init(name: "login", value: "oidc@colophon.dev"),
                           .init(name: "password", value: "colophon-oidc")]
        post.httpBody = body.percentEncodedQuery.map { Data($0.utf8) }

        // 4. Follow the approval/redirect chain until Dex bounces back to ABS, which in turn
        //    302s to `colophon://oauth?...`. A no-redirect transport surfaces that final hop.
        let noRedirect = URLSession(configuration: config, delegate: CallbackCaptureDelegate(scheme: "colophon"), delegateQueue: nil)
        let (_, response) = try await noRedirect.data(for: post)
        if let http = response as? HTTPURLResponse,
           let location = http.value(forHTTPHeaderField: "Location"),
           location.hasPrefix("colophon://"),
           let url = URL(string: location) {
            return url
        }
        throw OIDCError.callbackMissingCode
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

/// Suppresses redirects so a `colophon://` callback surfaces as a `Location` header instead of
/// failing when `URLSession` can't open the custom scheme.
private final class CallbackCaptureDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let scheme: String
    init(scheme: String) { self.scheme = scheme }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.scheme == scheme { completionHandler(nil) } else { completionHandler(request) }
    }
}
