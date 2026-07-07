import Foundation
import ABSRealtime

/// A `RealtimeSocketProtocol` test double: no socket.io connection. It replays a scripted list
/// of `ServerEvent`s through `events()` and records how often `reauthenticate()`/`stop()` are
/// called, so tests can assert on socket lifecycle without a live server.
@MainActor
final class FakeSocket: RealtimeSocketProtocol {
    private let scripted: [ServerEvent]
    private(set) var reauthenticateCount = 0
    private(set) var stopCount = 0

    init(scripted: [ServerEvent] = []) {
        self.scripted = scripted
    }

    func events() -> AsyncStream<ServerEvent> {
        let scripted = scripted
        return AsyncStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }

    func reauthenticate() async { reauthenticateCount += 1 }

    func stop() { stopCount += 1 }
}
