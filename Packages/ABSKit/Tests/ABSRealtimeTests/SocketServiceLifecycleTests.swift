import Foundation
import Testing
@testable import ABSRealtime

@Suite struct SocketServiceLifecycleTests {
    /// events() must be restart-safe: a second call finishes the superseded stream's
    /// continuation so its consumer's `for await` loop exits instead of hanging forever.
    /// No server needed — the URL is unreachable; only continuation handoff is under test.
    @Test @MainActor func secondEventsCallTerminatesFirstStream() async {
        let service = SocketService(
            serverURL: URL(string: "http://127.0.0.1:9")!,
            tokenProvider: { nil })

        let first = service.events()
        _ = service.events()

        var iterator = first.makeAsyncIterator()
        let element = await iterator.next()
        #expect(element == nil)

        service.stop()
    }
}
