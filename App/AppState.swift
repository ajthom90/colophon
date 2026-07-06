import Foundation
import SwiftUI
import ABSKit
import PlayerEngine

@Observable
final class AppState {
    enum Phase { case disconnected, connecting, connected }

    var phase: Phase = .disconnected
    var errorMessage: String?
    var libraries: [Library] = []
    var client: ABSClient?
    let playback = PlaybackController()

    private var auth: AuthManager?
    private let tokenStore = KeychainTokenStore()

    var deviceInfo: DeviceInfo {
        let id: String
        if let existing = UserDefaults.standard.string(forKey: "colophon.deviceId") {
            id = existing
        } else {
            id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: "colophon.deviceId")
        }
        #if os(macOS)
        let model = "Mac"
        #else
        let model = "iPhone"
        #endif
        return DeviceInfo(deviceId: id, clientVersion: "0.1.0", model: model)
    }

    func connect(serverURL: String, username: String, password: String) async {
        errorMessage = nil
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "Invalid server URL"; return
        }
        phase = .connecting
        do {
            let transport = URLSessionTransport()
            let status = try await ABSClient.status(baseURL: url, transport: transport)
            guard status.isInit else { throw ABSError.invalidResponse }
            guard let versionString = status.serverVersion,
                  let version = ServerVersion(versionString),
                  !(version < ABSKit.minimumServerVersion) else {
                throw ABSError.serverTooOld(found: status.serverVersion ?? "unknown")
            }
            let auth = AuthManager(baseURL: url, connectionID: url.absoluteString,
                                   transport: transport, store: tokenStore)
            _ = try await auth.login(username: username, password: password)
            let client = ABSClient(baseURL: url, transport: transport, auth: auth)
            self.auth = auth
            self.client = client
            self.libraries = try await client.libraries()
            phase = .connected
        } catch ABSError.http(status: 401) {
            phase = .disconnected
            errorMessage = "Wrong username or password"
        } catch {
            phase = .disconnected
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func startPlayback(item: LibraryItemSummary) async {
        guard let client else { return }
        do {
            let session = try await client.startPlayback(itemID: item.id, deviceInfo: deviceInfo)
            playback.onSyncDue = { [weak client] payload in
                guard let client else { return false }
                do {
                    try await client.syncSession(id: session.id, currentTime: payload.currentTime,
                                                 timeListened: payload.timeListened, duration: session.duration)
                    return true
                } catch {
                    return false  // keep accumulating; retried next interval
                }
            }
            playback.load(session: session) { track in
                client.publicTrackURL(sessionID: session.id, trackIndex: track.index)
            }
            playback.play()
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    #if DEBUG
    /// Headless E2E hook: if `COLOPHON_AUTO_CONNECT=serverURL|username|password` is set,
    /// auto-connect on launch; if `COLOPHON_AUTO_PLAY=1` is also set, start the first item;
    /// if `COLOPHON_AUTO_SEEK=<globalSeconds>` is also set, seek there once after playback starts.
    func runAutoConnectIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["COLOPHON_AUTO_CONNECT"] else { return }
        let parts = spec.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        await connect(serverURL: parts[0], username: parts[1], password: parts[2])
        guard phase == .connected, env["COLOPHON_AUTO_PLAY"] == "1",
              let library = libraries.first, let client else { return }
        guard let result = try? await client.items(libraryID: library.id, limit: 1, page: 0),
              let first = result.results.first else { return }
        await startPlayback(item: first)
        if let seekSpec = env["COLOPHON_AUTO_SEEK"], let target = TimeInterval(seekSpec) {
            playback.seek(toGlobal: target)
        }
    }
    #endif
}
