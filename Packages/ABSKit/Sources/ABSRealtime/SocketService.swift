import Foundation
import SocketIO

@MainActor
public final class SocketService {
    private let manager: SocketManager
    private let tokenProvider: @Sendable () async -> String?
    private var continuation: AsyncStream<ServerEvent>.Continuation?

    public init(serverURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        self.tokenProvider = tokenProvider
        self.manager = SocketManager(socketURL: serverURL, config: [
            .forceWebsockets(true), .version(.three), .compress,
            .reconnectWait(2), .reconnectWaitMax(10),
        ])
    }

    public func events() -> AsyncStream<ServerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        let socket = manager.defaultSocket
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in await self?.emitAuth() }
        }
        for name in ["user_item_progress_updated", "item_updated", "item_added",
                     "item_removed", "items_updated", "items_added"] {
            socket.on(name) { [weak self] payload, _ in
                Task { @MainActor in
                    if let event = ServerEvent.decode(event: name, payload: payload) {
                        self?.continuation?.yield(event)
                    }
                }
            }
        }
        socket.connect()
        return stream
    }

    /// Call after a token refresh: the server drops un-reauthenticated sockets' events.
    public func reauthenticate() async { await emitAuth() }

    public func stop() {
        continuation?.finish()
        manager.defaultSocket.disconnect()
    }

    private func emitAuth() async {
        guard let token = await tokenProvider() else { return }
        manager.defaultSocket.emit("auth", token)
    }
}
