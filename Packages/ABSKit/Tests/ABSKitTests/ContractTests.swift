import Foundation
import Testing
@testable import ABSKit

/// Run with: ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests
/// Requires `make server-up && make seed` first.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] != nil))
struct ContractTests {
    let base = URL(string: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] ?? "http://invalid")!
    let transport = URLSessionTransport()

    private func loggedInClient() async throws -> ABSClient {
        let store = InMemoryTokenStore()
        let auth = AuthManager(baseURL: base, connectionID: "contract", transport: transport, store: store)
        _ = try await auth.login(username: "root", password: "colophon-dev")
        return ABSClient(baseURL: base, transport: transport, auth: auth)
    }

    @Test func statusReportsSupportedVersion() async throws {
        let status = try await ABSClient.status(baseURL: base, transport: transport)
        #expect(status.isInit == true)
        #expect(status.serverVersion?.hasPrefix("2.3") == true)
    }

    @Test func fullPlaybackLifecycle() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        #expect(!libs.isEmpty)
        let page = try await client.items(libraryID: libs[0].id, limit: 10, page: 0)
        #expect(page.total >= 1)

        let device = DeviceInfo(deviceId: "contract-test", clientVersion: "0.1.0", model: "test")
        let envelope = try await client.startPlayback(itemID: page.results[0].id, deviceInfo: device)
        let session = envelope.session
        #expect(!session.audioTracks.isEmpty)
        #expect(session.playMethod == 0)  // seeded mp3s must direct-play

        // Empirical: public track URL serves audio for the track's own index value.
        let track = session.audioTracks[0]
        let trackURL = client.publicTrackURL(sessionID: session.id, trackIndex: track.index)
        var head = URLRequest(url: trackURL)
        head.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let ranged = try await transport.send(head)
        #expect(ranged.statusCode == 206, "expected partial content; got \(ranged.statusCode) — check index base or Range support")
        #expect(ranged.data.count == 1024)

        try await client.syncSession(id: session.id, currentTime: 30, timeListened: 15, duration: session.duration)
        try await client.closeSession(id: session.id, currentTime: 30, timeListened: 0, duration: session.duration)

        // Closed sessions are gone from server memory: sync must now 404.
        await #expect(throws: ABSError.http(status: 404)) {
            try await client.syncSession(id: session.id, currentTime: 31, timeListened: 1, duration: session.duration)
        }
    }

    @Test func coverEndpointIsUnauthenticatedAndServesImage() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let page = try await client.items(libraryID: libs[0].id, limit: 1, page: 0)
        let url = client.coverURL(itemID: page.results[0].id, width: 200, updatedAt: page.results[0].updatedAt)
        let unauthed = try await transport.send(URLRequest(url: url))   // no Authorization header
        #expect(unauthed.statusCode == 200, "seed must provide cover.jpg — re-run make seed after wiping devserver/data")
        #expect(unauthed.data.count > 1_000)                            // a real image, not an error body
    }
}
