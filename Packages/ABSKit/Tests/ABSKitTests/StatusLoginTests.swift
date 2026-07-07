import Foundation
import Testing
@testable import ABSKit
import ABSKitTestSupport

@Suite struct StatusLoginTests {
    let base = URL(string: "http://abs.test:13378")!

    @Test func statusRequestShape() {
        let req = ABSAPI.statusRequest(baseURL: base)
        #expect(req.url?.absoluteString == "http://abs.test:13378/status")
        #expect(req.httpMethod == "GET")
    }

    @Test func loginRequestSendsReturnTokensHeaderAndBody() throws {
        let req = ABSAPI.loginRequest(baseURL: base, username: "root", password: "pw")
        #expect(req.url?.absoluteString == "http://abs.test:13378/login")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]
        #expect(body == ["username": "root", "password": "pw"])
    }

    @Test func non2xxBecomesHTTPError() async throws {
        let mock = MockTransport()
        await mock.enqueue(status: 401, json: #"{"error":"Unauthorized"}"#)
        await #expect(throws: ABSError.http(status: 401)) {
            _ = try await ABSAPI.send(ABSAPI.statusRequest(baseURL: base), as: ServerStatus.self, via: mock)
        }
    }

    @Test func decodesThroughTransport() async throws {
        let mock = MockTransport()
        await mock.enqueue(status: 200, json: #"{"isInit":true,"serverVersion":"2.35.1"}"#)
        let s = try await ABSAPI.send(ABSAPI.statusRequest(baseURL: base), as: ServerStatus.self, via: mock)
        #expect(s.serverVersion == "2.35.1")
    }
}
