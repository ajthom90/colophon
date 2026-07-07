import Foundation
import Testing
@testable import ABSKit
import ABSKitTestSupport

@Suite struct OIDCFlowTests {
    let server = URL(string: "http://abs.test:13378")!
    let loginJSON = #"{"user":{"id":"u1","username":"oidc","accessToken":"acc-oidc","refreshToken":"ref-oidc"}}"#

    /// A matching-state, matching-code browser closure for the happy path.
    private func browser(returning url: String) -> @Sendable (URL) async throws -> URL {
        { _ in URL(string: url)! }
    }

    // MARK: - Happy path

    @Test func happyPathReturnsLoginResponse() async throws {
        let transport = MockTransport()
        // Step 1: /auth/openid → 302 with the IdP authorize URL (carrying server state) + a session cookie.
        await transport.enqueue(status: 302, json: "",
            headers: ["Location": "https://idp.example/dex/auth?client_id=audiobookshelf&state=STATE123&scope=openid",
                      "Set-Cookie": "abs.sid=abc; Path=/; HttpOnly"])
        // Step 3: /auth/openid/callback → 200 LoginResponse.
        await transport.enqueue(status: 200, json: loginJSON)

        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "fixed-verifier")
        let response = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=CODE456&state=STATE123"))

        #expect(response.user.accessToken == "acc-oidc")
        #expect(response.user.refreshToken == "ref-oidc")

        // The exchange (last request) must carry code, the captured state, and the verifier.
        let exchange = await transport.recorded.last!
        #expect(exchange.url?.path == "/auth/openid/callback")
        let q = queryDict(exchange.url!)
        #expect(q["code"] == "CODE456")
        #expect(q["state"] == "STATE123")
        #expect(q["code_verifier"] == "fixed-verifier")
    }

    @Test func authorizeRequestCarriesPKCEAndSpecParameters() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: ["Location": "https://idp.example/auth?state=S"])
        await transport.enqueue(status: 200, json: loginJSON)

        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "fixed-verifier")
        _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=C&state=S"))

        let authorize = await transport.recorded.first!
        #expect(authorize.url?.path == "/auth/openid")
        let q = queryDict(authorize.url!)
        #expect(q["response_type"] == "code")
        #expect(q["client_id"] == "Colophon")
        #expect(q["redirect_uri"] == "colophon://oauth")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["code_challenge"] == OIDCFlow.codeChallenge(for: "fixed-verifier"))
    }

    // MARK: - Failure modes

    @Test func nonRedirectStepOneThrowsServerRejected() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 400, json: "{}")
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        await #expect(throws: OIDCError.serverRejected(status: 400)) {
            _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=c&state=s"))
        }
    }

    @Test func missingLocationHeaderThrowsMissingAuthorizeURL() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: [:])
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        await #expect(throws: OIDCError.missingAuthorizeURL) {
            _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=c&state=s"))
        }
    }

    @Test func authorizeURLWithoutStateThrowsMissingAuthorizeURL() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: ["Location": "https://idp.example/auth?scope=openid"])
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        await #expect(throws: OIDCError.missingAuthorizeURL) {
            _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=c&state=s"))
        }
    }

    @Test func stateMismatchThrows() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: ["Location": "https://idp.example/auth?state=SERVER"])
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        await #expect(throws: OIDCError.stateMismatch) {
            _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=c&state=BROWSER"))
        }
    }

    @Test func callbackMissingCodeThrows() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: ["Location": "https://idp.example/auth?state=S"])
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        await #expect(throws: OIDCError.callbackMissingCode) {
            _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?state=S"))
        }
    }

    @Test func exchangeFailureThrowsExchangeFailed() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: ["Location": "https://idp.example/auth?state=S"])
        await transport.enqueue(status: 401, json: #"{"error":"invalid"}"#)
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        await #expect(throws: OIDCError.exchangeFailed(status: 401)) {
            _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=c&state=S"))
        }
    }

    @Test func malformedExchangeBodyThrowsExchangeFailedNotDecodingError() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: ["Location": "https://idp.example/auth?state=S"])
        await transport.enqueue(status: 200, json: "<html>not json</html>")
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        await #expect(throws: OIDCError.exchangeFailed(status: 200)) {
            _ = try await flow.authenticate(browser: browser(returning: "colophon://oauth?code=c&state=S"))
        }
    }

    @Test func wrongSchemeCallbackThrowsStateMismatch() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 302, json: "", headers: ["Location": "https://idp.example/auth?state=S"])
        let flow = OIDCFlow(serverURL: server, transport: transport, verifier: "v")
        // Correct state and code, but delivered on a scheme that isn't ours.
        await #expect(throws: OIDCError.stateMismatch) {
            _ = try await flow.authenticate(browser: browser(returning: "https://evil.example/oauth?code=c&state=S"))
        }
    }

    // MARK: - PKCE

    /// RFC 7636 Appendix B known-answer vector — independent of the implementation's own code path.
    @Test func codeChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OIDCFlow.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIs84HexCharacters() {
        let verifier = OIDCFlow.makeVerifier()
        let allHex = verifier.allSatisfy { $0.isHexDigit }
        #expect(verifier.count == 84)
        #expect(allHex)
    }

    @Test func generatedVerifiersAreDistinct() {
        #expect(OIDCFlow.makeVerifier() != OIDCFlow.makeVerifier())
    }

    // MARK: - Helpers

    private func queryDict(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}
