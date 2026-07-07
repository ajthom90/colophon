import Foundation
import Testing
@testable import ABSKit

@Suite struct TransportRedirectTests {
    @Test func followRedirectsDefaultsToTrue() {
        let transport = URLSessionTransport()
        #expect(transport.followRedirects == true)
    }

    @Test func nonFollowingTransportIsConstructible() {
        let transport = URLSessionTransport(followRedirects: false)
        #expect(transport.followRedirects == false)
    }

    @Test func redirectDelegateSuppressesRedirectByReturningNil() async {
        let delegate = NoRedirectSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com/original")!)
        defer { task.cancel() }

        let redirectResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/original")!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/redirected", "Set-Cookie": "session=abc"]
        )!
        let newRequest = URLRequest(url: URL(string: "https://example.com/redirected")!)

        let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirectResponse, newRequest: newRequest) { request in
                continuation.resume(returning: request)
            }
        }

        #expect(resolved == nil)
    }
}
