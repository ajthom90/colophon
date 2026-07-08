import Foundation
import Testing
@testable import ABSKit
import ABSKitTestSupport

@Suite struct PlaybackEndpointTests {
    let base = URL(string: "http://abs.test:13378")!

    private func makeSUT() async throws -> (ABSClient, MockTransport) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        return (ABSClient(baseURL: base, transport: transport, auth: auth), transport)
    }

    private let sessionJSON = #"{"id":"ses_1","libraryItemId":"li_1","duration":100,"playMethod":0,"startTime":5,"currentTime":5,"audioTracks":[{"index":1,"startOffset":0,"duration":100,"contentUrl":"/api/items/li_1/file/1","mimeType":"audio/mpeg"}],"chapters":[]}"#

    @Test func startPlaybackPostsDeviceInfoAndMimeTypes() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: sessionJSON)
        let device = DeviceInfo(deviceId: "dev-1", clientVersion: "0.1.0", model: "Mac16,1")
        let envelope = try await client.startPlayback(itemID: "li_1", deviceInfo: device)
        #expect(envelope.session.id == "ses_1")
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/items/li_1/play")
        #expect(req?.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Any]
        #expect((body["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "dev-1")
        #expect(body["mediaPlayer"] as? String == "AVPlayer")
        #expect((body["supportedMimeTypes"] as? [String])?.contains("audio/mpeg") == true)
        #expect(body["forceDirectPlay"] as? Bool == false)
        #expect(body["forceTranscode"] as? Bool == false)
    }

    /// `POST /api/items/:id/play/:episodeId` — mirrors `startPlayback`'s request-building
    /// (deviceInfo body, header, decode) but hits the episode-scoped path and threads
    /// `forceDirectPlay`/`forceTranscode` through (both default `false`, matching book playback's
    /// hardcoded behavior). Reuses the SAME `PlaybackSessionEnvelope`/`PlaybackSession` decode
    /// target as the book path — no parallel episode-only session type.
    @Test func playEpisodePostsToEpisodeScopedPathAndReusesSessionEnvelope() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: sessionJSON)
        let device = DeviceInfo(deviceId: "dev-1", clientVersion: "0.1.0", model: "Mac16,1")
        let envelope = try await client.playEpisode(itemID: "li_1", episodeId: "ep_1", deviceInfo: device)
        #expect(envelope.session.id == "ses_1")
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/items/li_1/play/ep_1")
        #expect(req?.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Any]
        #expect((body["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "dev-1")
        #expect(body["mediaPlayer"] as? String == "AVPlayer")
        #expect((body["supportedMimeTypes"] as? [String])?.contains("audio/mpeg") == true)
        #expect(body["forceDirectPlay"] as? Bool == false)
        #expect(body["forceTranscode"] as? Bool == false)
    }

    /// `forceDirectPlay`/`forceTranscode` thread through to the request body (unlike book
    /// `startPlayback`, which hardcodes both `false`) — needed for the HLS/direct-play rules.
    @Test func playEpisodeThreadsForceFlags() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: sessionJSON)
        let device = DeviceInfo(deviceId: "dev-1", clientVersion: "0.1.0", model: "Mac16,1")
        _ = try await client.playEpisode(
            itemID: "li_1", episodeId: "ep_1", deviceInfo: device,
            forceDirectPlay: true, forceTranscode: false)
        let req = await transport.recorded.first
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Any]
        #expect(body["forceDirectPlay"] as? Bool == true)
    }

    @Test func syncPostsPayload() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        try await client.syncSession(id: "ses_1", currentTime: 42.5, timeListened: 15, duration: 100)
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/session/ses_1/sync")
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Double]
        #expect(body == ["currentTime": 42.5, "timeListened": 15, "duration": 100])
    }

    @Test func closePostsSamePayloadShape() async throws {
        let (client, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        try await client.closeSession(id: "ses_1", currentTime: 99, timeListened: 3, duration: 100)
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/session/ses_1/close")
    }

    @Test func publicTrackURLUsesTrackIndexField() async throws {
        let (client, _) = try await makeSUT()
        let url = client.publicTrackURL(sessionID: "ses_1", trackIndex: 2)
        #expect(url.absoluteString == "http://abs.test:13378/public/session/ses_1/track/2")
    }
}
