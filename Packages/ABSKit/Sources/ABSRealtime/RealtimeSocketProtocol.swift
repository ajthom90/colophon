import Foundation

/// The realtime-socket surface `AppState` depends on. Abstracting `SocketService` behind a
/// protocol lets the app's unit tests inject a scripted `FakeSocket` (no real socket.io
/// connection) while production keeps using `SocketService` unchanged.
@MainActor
public protocol RealtimeSocketProtocol {
    /// Restart-safe event stream (see `SocketService.events()`).
    func events() -> AsyncStream<ServerEvent>
    /// Re-emit the auth token after a refresh.
    func reauthenticate() async
    /// Tear down the connection.
    func stop()
}

extension SocketService: RealtimeSocketProtocol {}
