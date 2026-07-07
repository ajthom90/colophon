import Foundation
import Testing
@testable import ABSKit

/// Live OIDC code-flow contract test against the dev stack (Dex + ABS).
///
/// Gated two ways, matching the plan:
///  1. Suite-level: only enabled when `ABS_CONTRACT_URL` is set, so CI and offline runs
///     SKIP cleanly and never touch the network.
///  2. Runtime: even when enabled, the single test first checks `GET /status` and no-ops
///     unless `openid` is an active auth method — so pointing `ABS_CONTRACT_URL` at a
///     password-only server doesn't spuriously fail.
///
/// Run (`make server-up && make seed` first, Dex active):
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

    /// A curl-equivalent "browser": walks the Dex hosted-login form headlessly, following the
    /// Task 5 spike transcript (docs/superpowers/spikes/2026-07-oidc-cookies.md). Receives the
    /// ABS-issued authorize URL and returns the `colophon://oauth?code&state` callback URL.
    ///
    /// One ephemeral session ≙ one browser: its cookie jar persists across every hop, and the
    /// delegate follows every redirect EXCEPT the final app-scheme one (URLSession can't open
    /// `colophon://`), which it surfaces as the mobile-redirect 302's `Location` header. The
    /// browser deliberately shares NO cookies with OIDCFlow's transport — the spike proved the
    /// browser-side hops (Dex pages, /auth/openid/mobile-redirect) are session-independent.
    @Sendable static func scriptedDexBrowser(_ authorizeURL: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: config,
                                 delegate: CallbackCaptureDelegate(scheme: "colophon"),
                                 delegateQueue: nil)

        // Transcript steps 2–3: GET the Dex authorize URL; Dex 302s through its `local`
        // connector to the login form. The final 200 is the form page.
        let (page, pageResponse) = try await session.data(from: authorizeURL)
        let html = String(decoding: page, as: UTF8.self)
        let formBase = pageResponse.url ?? authorizeURL

        // Transcript step 4: the form is
        //   <form method="post" action="/dex/auth/local/login?back=&amp;state=...">
        // — the action is HTML-escaped in the page source and relative to the Dex host.
        guard let rawAction = firstMatch(in: html, pattern: #"action="([^"]*/login[^"]*)""#),
              let formURL = URL(string: rawAction.replacingOccurrences(of: "&amp;", with: "&"),
                                relativeTo: formBase) else {
            throw OIDCError.missingAuthorizeURL
        }
        var post = URLRequest(url: formURL.absoluteURL)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [.init(name: "login", value: "oidc@colophon.dev"),
                           .init(name: "password", value: "colophon-oidc")]
        post.httpBody = body.percentEncodedQuery.map { Data($0.utf8) }

        // Transcript steps 4–5: dex (skipApprovalScreen: true) 303s straight to ABS's
        // /auth/openid/mobile-redirect, which 302s to colophon://oauth?code&state — the
        // delegate stops there, so that 302 is the response we see.
        let (_, response) = try await session.data(for: post)
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
