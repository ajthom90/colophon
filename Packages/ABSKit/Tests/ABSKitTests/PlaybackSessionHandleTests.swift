import Foundation
import Testing
@testable import ABSKit
import ABSKitTestSupport

@Suite struct PlaybackSessionHandleTests {
    let base = URL(string: "http://abs.test:13378")!
    let sessionJSON = #"{"id":"ses_1","libraryItemId":"li_1","duration":100,"playMethod":0,"startTime":0,"currentTime":0,"audioTracks":[],"chapters":[],"timeListening":0}"#

    private func makeSUT() async throws -> (PlaybackSessionHandle, MockTransport) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        try await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        let client = ABSClient(baseURL: base, transport: transport, auth: auth)
        let session = try JSONDecoder().decode(PlaybackSession.self, from: Data(sessionJSON.utf8))
        let envelope = PlaybackSessionEnvelope(session: session, rawData: Data(sessionJSON.utf8))
        return (PlaybackSessionHandle(client: client, envelope: envelope), transport)
    }

    @Test func syncPostsAndAccumulates() async throws {
        let (handle, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        #expect(await handle.sync(currentTime: 30, timeListened: 15) == true)
        let req = await transport.recorded.last
        #expect(req?.url?.path == "/api/session/ses_1/sync")
    }

    @Test func syncFallsBackToLocalUpsertOn404() async throws {
        let (handle, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")            // first sync OK (15s)
        _ = await handle.sync(currentTime: 15, timeListened: 15)
        await transport.enqueue(status: 404, json: "{}")            // server restarted
        await transport.enqueue(status: 200, json: "{}")            // local upsert OK
        #expect(await handle.sync(currentTime: 30, timeListened: 15) == true)
        let req = await transport.recorded.last
        #expect(req?.url?.path == "/api/session/local")
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Any]
        #expect(body["id"] as? String == "ses_1")
        #expect(body["currentTime"] as? Double == 30)
        #expect(body["timeListening"] as? Double == 30)             // session TOTAL, both syncs
        #expect(body["updatedAt"] != nil)
    }

    @Test func failedLocalUpsertReturnsFalse() async throws {
        let (handle, transport) = try await makeSUT()
        await transport.enqueue(status: 404, json: "{}")
        await transport.enqueue(status: 500, json: "{}")
        #expect(await handle.sync(currentTime: 10, timeListened: 10) == false)
    }

    @Test func closeFallsBackToLocalUpsertOn404() async throws {
        let (handle, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")            // one sync: total 15
        _ = await handle.sync(currentTime: 15, timeListened: 15)
        await transport.enqueue(status: 404, json: "{}")            // close hits restarted server
        await transport.enqueue(status: 200, json: "{}")            // local upsert OK
        await handle.close(currentTime: 20, timeListened: 5)
        let req = await transport.recorded.last
        #expect(req?.url?.path == "/api/session/local")
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Any]
        #expect(body["currentTime"] as? Double == 20)
        #expect(body["timeListening"] as? Double == 20)             // 15 synced + 5 at close
    }

    @Test func closePostsFinalPayload() async throws {
        let (handle, transport) = try await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        await handle.close(currentTime: 42, timeListened: 3)
        let req = await transport.recorded.last
        #expect(req?.url?.path == "/api/session/ses_1/close")
        let body = try? JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as? [String: Double]
        #expect(body?["currentTime"] == 42)
    }
}
