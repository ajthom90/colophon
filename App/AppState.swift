import Foundation
import SwiftUI
import ABSKit
import ABSRealtime
import PlayerEngine
import LibraryCache

@Observable
final class AppState {
    enum Phase { case disconnected, connecting, connected }

    var phase: Phase = .disconnected
    var errorMessage: String?
    var client: ABSClient?
    let playback = PlaybackController(backend: AVQueuePlayerBackend())
    let cache: LibraryCacheStore
    let coverStore: CoverStore

    /// UUID of the `CachedConnection` row for whatever server/user is currently signed in —
    /// the key views use to scope their `cache.observe*` calls, and the Keychain lookup key.
    private(set) var activeConnectionID: String?
    /// Last library ID `refreshItems` was asked to page — recorded so a future first-run/
    /// offline flow (M1b) can resume browsing the last-viewed library without a live server.
    private(set) var activeLibraryID: String?

    private var auth: AuthManager?
    private let tokenStore = KeychainTokenStore()
    private var sessionHandle: PlaybackSessionHandle?

    /// Real-time updates: one socket per active connection, one consumer task draining its
    /// event stream, one task forwarding `auth.tokenUpdates` into `socket.reauthenticate()`.
    private var socket: SocketService?
    private var socketTask: Task<Void, Never>?
    private var reauthTask: Task<Void, Never>?

    init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Colophon")
        // LibraryCacheStore.init creates its parent directory itself. A broken cache DB is
        // unrecoverable dev-state — crash loudly rather than run split-brain.
        cache = try! LibraryCacheStore(databaseURL: supportDir.appending(path: "cache.sqlite"))
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        coverStore = CoverStore(directory: cachesDir.appending(path: "covers"))
    }

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
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return DeviceInfo(deviceId: id, clientVersion: clientVersion, model: model)
    }

    func connect(serverURL: String, username: String, password: String) async {
        errorMessage = nil
        guard let url = normalizedServerURL(serverURL) else {
            errorMessage = "Invalid server URL"; return
        }
        // Tear down the previous connection's socket BEFORE any await, and clear the active
        // connection ID with it: otherwise the old socket stays live across the awaits below
        // while `activeConnectionID` may already reference the new connection, and a stray
        // server-A progress event would be upserted under server-B's ID.
        stopSocket()
        activeConnectionID = nil
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
            let connection = try findOrCreateConnection(address: url.absoluteString, username: username)
            // Awaited (not fire-and-forget) so migration can never race a fresh login's token
            // save — it must finish moving any legacy entry before `auth.login` writes new ones.
            await TokenMigration.migrateLegacyTokensIfNeeded(
                from: url.absoluteString, to: connection.id, store: tokenStore)
            let auth = AuthManager(baseURL: url, connectionID: connection.id,
                                   transport: transport, store: tokenStore)
            _ = try await auth.login(username: username, password: password)
            let client = ABSClient(baseURL: url, transport: transport, auth: auth)
            self.auth = auth
            self.client = client
            self.activeConnectionID = connection.id
            let libs = try await client.libraries()
            try cache.upsertLibraries(libs.enumerated().map { index, lib in
                CachedLibrary(id: lib.id, connectionID: connection.id, name: lib.name,
                              mediaType: lib.mediaType, displayOrder: lib.displayOrder ?? index)
            }, connectionID: connection.id)
            // Real-time updates: one socket per active connection (the previous connection's
            // socket was torn down at the top of connect(), before any await).
            let service = SocketService(serverURL: url) { [weak auth] in
                try? await auth?.currentAccessToken()
            }
            socket = service
            socketTask = Task { [weak self] in
                for await event in service.events() {
                    await self?.apply(event)
                }
            }
            reauthTask = Task { [weak self] in
                // `auth` is an actor: reading its `tokenUpdates` stream (a Sendable value)
                // requires an isolation hop, but the stream itself can then be iterated freely.
                guard let updates = await self?.auth?.tokenUpdates else { return }
                for await _ in updates {
                    await self?.socket?.reauthenticate()
                }
            }
            phase = .connected
        } catch ABSError.http(status: 401) {
            stopSocket()
            phase = .disconnected
            activeConnectionID = nil   // no stale ID while disconnected
            errorMessage = "Wrong username or password"
        } catch {
            stopSocket()
            phase = .disconnected
            activeConnectionID = nil   // no stale ID while disconnected
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Tears down the live socket and both of its driving tasks. Called at the top of
    /// `connect()` (before any await — no old socket may outlive an `activeConnectionID`
    /// change) and, defensively, on every path that leaves `phase != .connected`.
    private func stopSocket() {
        socket?.stop()
        socket = nil
        socketTask?.cancel()
        socketTask = nil
        reauthTask?.cancel()
        reauthTask = nil
    }

    /// Applies a decoded server event to local state. `progressUpdated`/`progressBatch` upsert
    /// straight into the cache (last-write-wins by `lastUpdate`, enforced in
    /// `LibraryCacheStore.upsertProgress`); item lifecycle events do a coarse re-page of
    /// whatever library is currently open (M1a scope — per-item patch is M1c polish).
    private func apply(_ event: ServerEvent) async {
        guard let connectionID = activeConnectionID else { return }
        switch event {
        case .progressUpdated(let update):
            try? cache.upsertProgress(CachedProgress(
                connectionID: connectionID, itemID: update.itemID, episodeID: update.episodeID,
                currentTime: update.currentTime, isFinished: update.isFinished, lastUpdate: update.lastUpdate))
        case .progressBatch(let updates):
            for update in updates {
                try? cache.upsertProgress(CachedProgress(
                    connectionID: connectionID, itemID: update.itemID, episodeID: update.episodeID,
                    currentTime: update.currentTime, isFinished: update.isFinished, lastUpdate: update.lastUpdate))
            }
        case .itemChanged, .itemsChanged, .itemRemoved:
            if let libraryID = activeLibraryID { try? await refreshItems(libraryID: libraryID) }
        }
    }

    /// Trims whitespace, drops a trailing "/", and lowercases scheme+host so the same server
    /// typed as "Http://NAS.local:13378/" and "http://nas.local:13378" resolve to the same
    /// `CachedConnection` row instead of silently creating a second one.
    private func normalizedServerURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var stripped = trimmed
        while stripped.hasSuffix("/") { stripped.removeLast() }
        guard var comps = URLComponents(string: stripped),
              let scheme = comps.scheme, let host = comps.host, !host.isEmpty else { return nil }
        comps.scheme = scheme.lowercased()
        comps.host = host.lowercased()
        return comps.url
    }

    private func findOrCreateConnection(address: String, username: String) throws -> CachedConnection {
        if let existing = try cache.connections().first(where: {
            $0.address == address && $0.username == username
        }) {
            return existing
        }
        let fresh = CachedConnection(id: UUID().uuidString, address: address,
                                     name: URL(string: address)?.host() ?? address,
                                     username: username, authMethod: "local",
                                     sortIndex: try cache.connections().count)
        try cache.upsertConnection(fresh)
        return fresh
    }

    /// Pages `client.items` (50/page) into the cache until the server-reported total is
    /// satisfied or a 20-page (1000-item) cap is hit — a deliberate M1a limit; full unbounded
    /// paging is out of scope until it's needed.
    func refreshItems(libraryID: String) async throws {
        guard let client, let connectionID = activeConnectionID else {
            throw ABSError.notAuthenticated
        }
        activeLibraryID = libraryID
        let limit = 50
        var accumulated = 0
        for page in 0..<20 {
            let result = try await client.items(libraryID: libraryID, limit: limit, page: page)
            let mapped = result.results.map { item in
                CachedItem(id: item.id, connectionID: connectionID, libraryID: libraryID,
                          title: item.media.metadata.title ?? "Untitled",
                          authorName: item.media.metadata.authorName,
                          duration: item.media.duration, updatedAt: item.updatedAt)
            }
            try cache.upsertItemsPage(mapped, connectionID: connectionID, libraryID: libraryID)
            accumulated += result.results.count
            if result.results.isEmpty || accumulated >= result.total { break }
        }
    }

    /// Retire the current session completely (ordering matters: flush → detach sync callback →
    /// close server-side → tear down local playback). pause() also flushes, but via a
    /// fire-and-forget Task with no ordering guarantee against the next line — so flush
    /// deterministically before severing onSyncDue (idempotent: a harmless no-op if pause()'s
    /// internal flush already landed).
    private func retireCurrentSession() async {
        guard let handle = sessionHandle else { return }
        playback.pause()
        await playback.flushOnly()
        playback.onSyncDue = nil
        await handle.close(currentTime: playback.globalTime, timeListened: 0)
        playback.unload()
        sessionHandle = nil
    }

    func startPlayback(itemID: String) async {
        guard let client else { return }
        // Retire the old session completely before touching the new one.
        await retireCurrentSession()
        do {
            let envelope = try await client.startPlayback(itemID: itemID, deviceInfo: deviceInfo)
            let handle = PlaybackSessionHandle(client: client, envelope: envelope)
            sessionHandle = handle
            playback.onSyncDue = { payload in
                await handle.sync(currentTime: payload.currentTime, timeListened: payload.timeListened)
            }
            let ordered = envelope.session.audioTracks.sorted { $0.startOffset < $1.startOffset }
            let urls = ordered.map { client.publicTrackURL(sessionID: envelope.session.id, trackIndex: $0.index) }
            playback.load(session: envelope.session, trackURLs: urls)
            playback.play()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Scene backgrounding: flush accumulated listened-time WITHOUT pausing — background
    /// audio must keep playing (server-side 36h reaping + 404-recovery cover full termination).
    func flushForBackground() {
        Task { await playback.flushOnly() }
    }

    /// Entry point for a future explicit "stop" affordance.
    func closeCurrentSession() async {
        await retireCurrentSession()
    }

    #if DEBUG
    /// Headless E2E hook: if `COLOPHON_AUTO_CONNECT=serverURL|username|password` is set,
    /// auto-connect on launch; if `COLOPHON_AUTO_PLAY=1` is also set, start the first item;
    /// if `COLOPHON_AUTO_MUTE=1` is also set, mute the backend before playback (keeps CI/E2E
    /// runs silent); if `COLOPHON_AUTO_SEEK=<globalSeconds>` is also set, seek there once after
    /// playback starts.
    func runAutoConnectIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["COLOPHON_AUTO_CONNECT"] else { return }
        let parts = spec.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        if env["COLOPHON_AUTO_MUTE"] == "1" { playback.muted = true }
        await connect(serverURL: parts[0], username: parts[1], password: parts[2])
        guard phase == .connected, env["COLOPHON_AUTO_PLAY"] == "1",
              let client, let connectionID = activeConnectionID else { return }
        // Views now get their item lists from cache observation (an AsyncSequence), which
        // isn't a natural fit for this one-shot debug hook — fetch the library list directly
        // from the client (cheap; already just wrote it to cache in `connect`), then reuse
        // the real `refreshItems` pager (same code path `LibraryItemsView` drives) so this
        // hook also exercises and populates the item cache instead of bypassing it.
        guard let libraries = try? await client.libraries(), let library = libraries.first else { return }
        try? await refreshItems(libraryID: library.id)
        guard let first = try? cache.items(connectionID: connectionID, libraryID: library.id).first else { return }
        await startPlayback(itemID: first.id)
        if let seekSpec = env["COLOPHON_AUTO_SEEK"], let target = TimeInterval(seekSpec) {
            playback.seek(toGlobal: target)
        }
    }
    #endif
}
