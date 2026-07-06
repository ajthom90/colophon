import Foundation

/// Owns one playback session's server lifecycle: periodic syncs, 404 recovery
/// (server restart wipes in-memory sessions), and close-with-flush.
public actor PlaybackSessionHandle {
    private let client: ABSClient
    private let envelope: PlaybackSessionEnvelope
    private var totalListened: Double

    public init(client: ABSClient, envelope: PlaybackSessionEnvelope) {
        self.client = client
        self.envelope = envelope
        self.totalListened = 0
    }

    public var sessionID: String { envelope.session.id }

    /// Returns true when the server acknowledged the listened time (directly or via local upsert).
    public func sync(currentTime: Double, timeListened: Double) async -> Bool {
        do {
            try await client.syncSession(id: envelope.session.id, currentTime: currentTime,
                                         timeListened: timeListened, duration: envelope.session.duration)
            totalListened += timeListened
            return true
        } catch ABSError.http(status: 404) {
            return await localUpsert(currentTime: currentTime, timeListened: timeListened)
        } catch {
            return false
        }
    }

    public func close(currentTime: Double, timeListened: Double) async {
        do {
            try await client.closeSession(id: envelope.session.id, currentTime: currentTime,
                                          timeListened: timeListened, duration: envelope.session.duration)
            totalListened += timeListened
        } catch ABSError.http(status: 404) {
            _ = await localUpsert(currentTime: currentTime, timeListened: timeListened)
        } catch {
            // Best-effort close; progress was carried by earlier syncs.
        }
    }

    private func localUpsert(currentTime: Double, timeListened: Double) async -> Bool {
        do {
            try await client.postLocalSession(rawData: envelope.rawData,
                                              currentTime: currentTime,
                                              totalListened: totalListened + timeListened)
            totalListened += timeListened
            return true
        } catch {
            return false
        }
    }
}
