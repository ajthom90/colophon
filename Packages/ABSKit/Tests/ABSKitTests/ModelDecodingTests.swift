import Foundation
import Testing
@testable import ABSKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

@Suite struct ModelDecodingTests {
    private let decoder = JSONDecoder()

    @Test func decodesServerStatus() throws {
        let s = try decoder.decode(ServerStatus.self, from: fixture("status"))
        #expect(s.isInit == true)
        #expect(s.serverVersion == "2.35.1")
        #expect(s.authMethods == ["local"])
    }

    @Test func decodesLoginResponseWithTokens() throws {
        let r = try decoder.decode(LoginResponse.self, from: fixture("login"))
        #expect(r.user.accessToken == "eyJ.access.1")
        #expect(r.user.refreshToken == "eyJ.refresh.1")
        #expect(r.user.username == "root")
    }

    @Test func decodesLibraries() throws {
        let r = try decoder.decode(LibrariesResponse.self, from: fixture("libraries"))
        #expect(r.libraries.count == 1)
        #expect(r.libraries[0].mediaType == "book")
        #expect(r.libraries[0].name == "Books")
    }

    @Test func decodesItemsPage() throws {
        let p = try decoder.decode(ItemsPage.self, from: fixture("items_page"))
        #expect(p.total == 1)
        #expect(p.results[0].media.metadata.title == "The Art of War")
        #expect(p.results[0].media.metadata.authorName == "Sun Tzu")
        #expect(p.results[0].updatedAt == 1_751_060_000_000)
    }

    @Test func decodesPlaybackSession() throws {
        let s = try decoder.decode(PlaybackSession.self, from: fixture("playback_session"))
        #expect(s.id == "ses_xyz789")
        #expect(s.startTime == 125.0)
        #expect(s.audioTracks.count == 2)
        #expect(s.audioTracks[1].startOffset == 600.2)
        #expect(s.audioTracks[1].index == 2)
        #expect(s.chapters.count == 2)
    }

    @Test func toleratesUnknownAndMissingFields() throws {
        let json = #"{"id":"ses_1","libraryItemId":"li_9","duration":10,"playMethod":0,"startTime":0,"currentTime":0,"audioTracks":[],"chapters":[],"someFutureField":{"x":1}}"#
        let s = try decoder.decode(PlaybackSession.self, from: Data(json.utf8))
        #expect(s.displayTitle == nil)
        #expect(s.audioTracks.isEmpty)
    }

    @Test func deviceInfoEncodesWithDefaults() throws {
        let device = DeviceInfo(deviceId: "dev-1", clientVersion: "0.1.0", model: "Mac16,1")
        let data = try JSONEncoder().encode(device)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(json == [
            "deviceId": "dev-1",
            "clientName": "Colophon",
            "clientVersion": "0.1.0",
            "manufacturer": "Apple",
            "model": "Mac16,1",
        ])
    }
}
