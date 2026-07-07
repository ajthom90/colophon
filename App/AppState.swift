import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif
import AuthenticationServices
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
    /// Non-blocking "couldn't refresh" banner for `LibraryItemsView`, distinct from
    /// `errorMessage` (which drives the blocking playback/connect alert). Set by `refreshItems`
    /// only when the refresh failed AND the cache already had rows for that library (so there's
    /// a still-usable screen worth keeping up); tagged with the failing library's ID so a view
    /// for a *different* library never shows someone else's failure, and cleared on the next
    /// successful refresh of that same library. When the cache is empty, `refreshItems` rethrows
    /// instead and the existing loadError/ContentUnavailableView path in `LibraryItemsView`
    /// handles it.
    private(set) var refreshBanner: (libraryID: String, message: String)?
    let playback = PlaybackController(backend: AVQueuePlayerBackend())
    let cache: LibraryCacheStore
    let coverStore: CoverStore

    /// UserDefaults key persisting the last connection the user activated, so `ConnectionsView`
    /// can auto-resume it on the next launch — the load-bearing half of the offline first-run
    /// fix (a relaunch with a dead server still lands the user in their cached library).
    static let lastActiveConnectionIDKey = "colophon.lastActiveConnectionID"

    /// Settings keys (Global Constraints — exact strings, `@AppStorage`-compatible so
    /// `SettingsView`'s property wrappers and these plain `UserDefaults` reads always agree).
    /// `AppState` isn't a `View`, so it can't use `@AppStorage` itself; it reads the same
    /// `UserDefaults.standard` keys directly instead.
    static let defaultRateKey = "colophon.defaultRate"
    static let skipIntervalKey = "colophon.skipInterval"

    /// The user's default playback rate (Settings), applied to every freshly opened book in
    /// `startPlayback` — per-book overrides are M2/CloudSync scope. `UserDefaults.double` returns
    /// 0 for an absent key (nothing set yet, or `SettingsView` never opened), which reads as the
    /// documented default of 1.0×.
    private static func storedDefaultRate() -> Double {
        let stored = UserDefaults.standard.double(forKey: defaultRateKey)
        return stored == 0 ? 1.0 : stored
    }

    /// The user's skip-interval preference (Settings), seconds — one of 10/15/30/45. Same
    /// unset-reads-as-default treatment as `storedDefaultRate`: an absent key reads as 15.
    private static func storedSkipInterval() -> Int {
        let stored = UserDefaults.standard.integer(forKey: skipIntervalKey)
        return stored == 0 ? 15 : stored
    }

    /// UUID of the `CachedConnection` row for whatever server/user is currently signed in —
    /// the key views use to scope their `cache.observe*` calls, and the Keychain lookup key.
    private(set) var activeConnectionID: String?
    /// Whether the active connection currently has a *live* server behind it. `false` after a
    /// cached-first `activateConnection` until (and unless) the background `POST /api/authorize`
    /// probe succeeds; distinguishes "browsing cached rows offline" from "connected and syncing".
    private(set) var isOnline = false
    /// Connection IDs whose stored tokens are missing or rejected (a failed probe / signed-out
    /// row). Surfaced as a badge in `ConnectionsView`; tapping such a row routes to re-auth.
    /// Cleared the moment a (re)connect or a successful probe proves the credentials good.
    private(set) var needsSignIn: Set<String> = []
    /// The observed connection list `ConnectionsView` renders. Refreshed from the cache by
    /// `loadConnections()` at boot and after every connection mutation (activate/connect/
    /// signOut/remove) — a simple observed array rather than a live `ValueObservation`, which
    /// is more than this rarely-changing, user-driven list needs.
    private(set) var connections: [CachedConnection] = []
    /// The last connection the user activated (mirrors `lastActiveConnectionIDKey`). Read by
    /// `ConnectionsView` to auto-resume on launch.
    private(set) var lastActiveConnectionID: String? =
        UserDefaults.standard.string(forKey: AppState.lastActiveConnectionIDKey)
    /// Which connection OWNS the currently-playing session. Set when `startPlayback` succeeds,
    /// cleared when the session is retired. Playback policy: switching the active connection
    /// leaves this (and the player) untouched — only signing out / removing *this* connection
    /// retires the session first.
    private var playingConnectionID: String?
    /// Last library ID `refreshItems` was asked to page — recorded so a future first-run/
    /// offline flow (M1b) can resume browsing the last-viewed library without a live server.
    private(set) var activeLibraryID: String?

    private var auth: AuthManager?
    private let tokenStore: any TokenStore
    private var sessionHandle: PlaybackSessionHandle?

    /// Test seams (default args reproduce production exactly, so `ColophonApp`'s `AppState()`
    /// is unchanged): `transport` stands in for a real `URLSessionTransport` (MockTransport in
    /// tests), and `socketFactory` builds the realtime socket (a scripted `FakeSocket` in tests).
    private let transport: Transport
    /// `OIDCFlow` needs a DEDICATED no-redirect, cookie-jar transport (it reads the 302 to the IdP
    /// itself; a redirect-following transport like `transport` above would silently follow that
    /// 302 and hand OIDCFlow the IdP's eventual 200 page instead, misreporting `.serverRejected`).
    /// `nil` in production lets `OIDCFlow` build its own; tests inject the SAME `MockTransport`
    /// used for `/status`/`/libraries` so one FIFO queue can script the whole `connectWithOIDC` call.
    private let oidcTransport: Transport?
    private let socketFactory: (URL, @escaping @Sendable () async -> String?) -> any RealtimeSocketProtocol

    /// Real-time updates: one socket per active connection, one consumer task draining its
    /// event stream, one task forwarding `auth.tokenUpdates` into `socket.reauthenticate()`.
    private var socket: (any RealtimeSocketProtocol)?
    private var socketTask: Task<Void, Never>?
    private var reauthTask: Task<Void, Never>?
    /// Reentrancy guard for `startPlayback`: without it, two rapid taps both pass
    /// `retireCurrentSession` (handle nil) and both await `client.startPlayback`; if response A
    /// lands after B, the user hears the wrong item and B's server session leaks open.
    private var isStartingPlayback = false
    /// Reentrancy guard for `activateConnection`'s synchronous section — see its doc comment.
    private var activatingConnectionID: String?
    /// The background probe kicked off by the most recent `activateConnection` call — see its
    /// doc comment. Not awaited by `activateConnection` itself; exists so a fresh activation can
    /// cancel whatever probe preceded it.
    private var probeTask: Task<Void, Never>?

    /// Every argument defaults to production behavior; tests override them to run entirely
    /// offline (MockTransport, temp-dir cache, FakeSocket, `InMemoryTokenStore` — the Keychain
    /// is host-app-entitlement-bound and must never be touched by unit tests).
    init(
        transportProvider: @escaping @Sendable () -> Transport = { URLSessionTransport() },
        cacheDirectory: URL? = nil,
        socketFactory: ((URL, @escaping @Sendable () async -> String?) -> any RealtimeSocketProtocol)? = nil,
        tokenStore: (any TokenStore)? = nil,
        oidcTransportProvider: (@Sendable () -> Transport)? = nil
    ) {
        self.transport = transportProvider()
        self.oidcTransport = oidcTransportProvider?()
        self.tokenStore = tokenStore ?? KeychainTokenStore()
        self.socketFactory = socketFactory ?? { url, tokenProvider in
            SocketService(serverURL: url, tokenProvider: tokenProvider)
        }
        let supportDir = cacheDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Colophon")
        // LibraryCacheStore.init creates its parent directory itself. A broken cache DB is
        // unrecoverable dev-state — crash loudly rather than run split-brain.
        cache = try! LibraryCacheStore(databaseURL: supportDir.appending(path: "cache.sqlite"))
        // Isolate covers alongside an injected cache dir; otherwise keep the production Caches dir.
        let coversDir = cacheDirectory?.appending(path: "covers")
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "covers")
        coverStore = CoverStore(directory: coversDir)
        // Seed the observed connections array now, not just on the first `.task` after launch —
        // otherwise `ColophonApp`'s `app.connections.isEmpty` check on first render sees an empty
        // array and flashes `ConnectView` for one frame before `.task` runs `loadConnections()`,
        // even when connections already exist on disk.
        connections = (try? cache.connections()) ?? []
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
        // Closes the same-frame double-tap window: without this, two rapid taps both race past
        // the stopSocket/ID-nil prefix below and each spins up its own socket, leaking one live.
        guard phase != .connecting else { return }
        errorMessage = nil
        guard let url = normalizedServerURL(serverURL) else {
            errorMessage = "Invalid server URL"; return
        }
        // Tear down the previous connection's socket BEFORE any await, and clear the active
        // connection ID with it: otherwise the old socket stays live across the awaits below
        // while `activeConnectionID` may already reference the new connection, and a stray
        // server-A progress event would be upserted under server-B's ID. The refresh banner is
        // reset here too — a stale "couldn't refresh" from the previous connection's library
        // must not bleed into the new connection (library IDs could even collide across servers).
        stopSocket()
        activeConnectionID = nil
        refreshBanner = nil
        phase = .connecting
        do {
            let transport = self.transport
            let status = try await ABSClient.status(baseURL: url, transport: transport)
            try checkVersionGate(status)
            let connection = try findOrCreateConnection(address: url.absoluteString, username: username)
            // Awaited (not fire-and-forget) so migration can never race a fresh login's token
            // save — it must finish moving any legacy entry before `auth.login` writes new ones.
            await TokenMigration.migrateLegacyTokensIfNeeded(
                from: url.absoluteString, to: connection.id, store: tokenStore)
            let auth = AuthManager(baseURL: url, connectionID: connection.id,
                                   transport: transport, store: tokenStore)
            _ = try await auth.login(username: username, password: password)
            try await completeConnection(connection: connection, auth: auth, url: url)
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

    /// Probes `/status` for a not-yet-connected server, normalizing the URL the same way
    /// `connect()`/`connectWithOIDC()` do. Read-only — never touches `phase`/`activeConnectionID`
    /// — so `ConnectView` can call it freely while the user is still choosing a sign-in method.
    func fetchStatus(serverURL: String) async throws -> ServerStatus {
        guard let url = normalizedServerURL(serverURL) else { throw ABSError.invalidResponse }
        return try await ABSClient.status(baseURL: url, transport: transport)
    }

    /// OIDC counterpart to `connect(serverURL:username:password:)`: same reentrancy guard and
    /// stopSocket/ID-nil/refreshBanner prefix, the same `/status` version gate, then the OIDC
    /// authorization-code flow (via the injected `browser`, which the view supplies from
    /// `@Environment(\.webAuthenticationSession)`) in place of a password login. The connection's
    /// username is only known once `OIDCFlow.authenticate` returns the IdP-issued identity, so
    /// find-or-create necessarily happens after that — unlike the password path, where the user
    /// supplies the username up front.
    func connectWithOIDC(serverURL: String, browser: @Sendable (URL) async throws -> URL) async {
        guard phase != .connecting else { return }
        errorMessage = nil
        guard let url = normalizedServerURL(serverURL) else {
            errorMessage = "Invalid server URL"; return
        }
        stopSocket()
        activeConnectionID = nil
        refreshBanner = nil
        phase = .connecting
        do {
            let transport = self.transport
            let status = try await ABSClient.status(baseURL: url, transport: transport)
            try checkVersionGate(status)
            let flow = OIDCFlow(serverURL: url, transport: oidcTransport)
            let loginResponse = try await flow.authenticate(browser: browser)
            let connection = try findOrCreateConnection(
                address: url.absoluteString, username: loginResponse.user.username, authMethod: "openid")
            let auth = AuthManager(baseURL: url, connectionID: connection.id,
                                   transport: transport, store: tokenStore)
            try await auth.completeOIDC(loginResponse: loginResponse)
            try await completeConnection(connection: connection, auth: auth, url: url)
        } catch {
            stopSocket()
            phase = .disconnected
            activeConnectionID = nil   // no stale ID while disconnected
            // A user-dismissed ASWebAuthenticationSession sheet is not a failure worth an alert —
            // `session.authenticate(...)` throws `.canceledLogin` (NSError code 1, domain
            // ASWebAuthenticationSessionErrorDomain) and, unwrapped, that surfaced as a raw
            // "operation couldn't be completed (error 1)" alert. Treat it as a silent no-op: the
            // guards above already reset phase/activeConnectionID, so the user just lands back on
            // the connect step with no error message. Every other failure still surfaces normally.
            if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                return
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The version gate shared by both sign-in paths: the server must be initialized and at or
    /// above `ABSKit.minimumServerVersion`, checked BEFORE either password login or the OIDC
    /// browser hop — so an old/uninitialized server is rejected without prompting for credentials
    /// or opening a sign-in sheet.
    private func checkVersionGate(_ status: ServerStatus) throws {
        guard status.isInit else { throw ABSError.invalidResponse }
        guard let versionString = status.serverVersion,
              let version = ServerVersion(versionString),
              !(version < ABSKit.minimumServerVersion) else {
            throw ABSError.serverTooOld(found: status.serverVersion ?? "unknown")
        }
    }

    /// The tail both sign-in paths share once they hold an authenticated `AuthManager`: build the
    /// client, publish connection state, fetch+cache the library list, and stand up the realtime
    /// socket. Only reached after a successful login/OIDC exchange, so `phase` ends `.connected`.
    private func completeConnection(connection: CachedConnection, auth: AuthManager, url: URL) async throws {
        let transport = self.transport
        let client = ABSClient(baseURL: url, transport: transport, auth: auth)
        self.auth = auth
        self.client = client
        self.activeConnectionID = connection.id
        let libs = try await client.libraries()
        try cache.upsertLibraries(libs.enumerated().map { index, lib in
            CachedLibrary(id: lib.id, connectionID: connection.id, name: lib.name,
                          mediaType: lib.mediaType, displayOrder: lib.displayOrder ?? index)
        }, connectionID: connection.id)
        startSocket(url: url, auth: auth)
        // A fresh login/OIDC exchange proves the credentials — this connection no longer
        // needs sign-in, and it's live.
        needsSignIn.remove(connection.id)
        isOnline = true
        persistLastActive(connection.id)
        loadConnections()
        phase = .connected
    }

    /// Stands up the realtime socket for `auth`/`url`: one socket, one consumer task draining its
    /// event stream, one task forwarding `auth.tokenUpdates` into `socket.reauthenticate()`. Tears
    /// down any existing socket FIRST (defensive, not just the caller's responsibility): with
    /// `activateConnection`'s probe now detached, two overlapping probes for the same connection
    /// can both reach this method, and without this the second call's `socket = service` would
    /// leak the first socket and its two tasks permanently. Shared by the sign-in tail
    /// (`completeConnection`) and the online branch of `activateConnection`.
    private func startSocket(url: URL, auth: AuthManager) {
        stopSocket()
        let tokenProvider: @Sendable () async -> String? = { [weak auth] in
            try? await auth?.currentAccessToken()
        }
        let service = socketFactory(url, tokenProvider)
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
    }

    // MARK: - Connections

    /// Refreshes the observed `connections` array from the cache. Cheap and synchronous; called
    /// at boot and after every connection mutation so `ConnectionsView` always mirrors the store.
    func loadConnections() {
        connections = (try? cache.connections()) ?? []
    }

    private func persistLastActive(_ id: String) {
        lastActiveConnectionID = id
        UserDefaults.standard.set(id, forKey: Self.lastActiveConnectionIDKey)
    }

    /// Activates a stored connection with CACHED-FIRST semantics — THE offline first-run fix.
    /// Synchronously (before any network `await`) it makes the connection's cached libraries
    /// browsable: `activeConnectionID` + `phase = .connected` with `isOnline = false`, then
    /// RETURNS — a caller `await`ing this method resumes immediately, so `ConnectionsView`/
    /// `LibrariesView` navigate without waiting on the network. The stored-token probe is kicked
    /// off in a detached `probeTask` that this method does not await:
    ///   • no tokens stored          → mark `needsSignIn`, stay cached/offline (never probes;
    ///     this check IS still inline/synchronous, since it's an in-memory/Keychain lookup, not
    ///     the network, and a caller checking `needsSignIn` right after `activateConnection`
    ///     returns needs to see it).
    ///   • probe succeeds            → `isOnline = true`, socket up, library list refreshed.
    ///   • probe 401 → refresh fails → `reauthRequired` → mark `needsSignIn`, stay cached/offline.
    ///   • host down / transport err → stay cached/offline (isOnline false); the per-library
    ///     `refreshBanner` and the `LibrariesView` offline banner drive the retry affordance.
    /// Playback is untouched throughout (only the previous socket is torn down; the player keeps
    /// running) — switching connections mid-listen keeps playing, per the Global Constraints.
    func activateConnection(_ id: String) async {
        // Reentrancy guard for the SYNCHRONOUS section below: without it, two near-simultaneous
        // activations of the SAME id (a double-tap) could both run it, each building its own
        // `AuthManager`/`ABSClient` and kicking off its own probe. Cleared the moment this method
        // returns, which is fast now that the probe no longer blocks it.
        guard activatingConnectionID != id else { return }
        activatingConnectionID = id
        defer { activatingConnectionID = nil }

        guard let connection = try? cache.connections().first(where: { $0.id == id }),
              let url = URL(string: connection.address) else { return }
        // A fresh activation supersedes whatever probe the last one kicked off. Cancellation is
        // cooperative (an in-flight `authorize()` won't necessarily observe it right away), so
        // this is a best-effort dedup — the authoritative guard is still each probe's own
        // `activeConnectionID == id` check after every await, below.
        probeTask?.cancel()
        // Deactivate the previous connection's socket before switching IDs (a stray old-server
        // event must never land under the new connection's ID). The player is deliberately left
        // running — see the playback policy above.
        stopSocket()
        errorMessage = nil
        refreshBanner = nil
        isOnline = false
        activeLibraryID = nil
        activeConnectionID = id
        persistLastActive(id)
        loadConnections()
        phase = .connected   // cached browsing is live from here — server up or not.

        // No stored credentials: surface re-auth, don't probe (nothing to probe with).
        guard await tokenStore.tokens(for: id) != nil else {
            client = nil
            auth = nil
            needsSignIn.insert(id)
            return
        }
        let auth = AuthManager(baseURL: url, connectionID: id, transport: transport, store: tokenStore)
        let client = ABSClient(baseURL: url, transport: transport, auth: auth)
        self.auth = auth
        self.client = client

        // The network probe: detached so `activateConnection` returns now, with cached browsing
        // already live. Every branch re-checks `activeConnectionID == id` since a newer
        // activation (of this id or a different one) may have superseded this probe by the time
        // any await resumes.
        probeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.authorize()
                guard self.activeConnectionID == id else { return }
                self.needsSignIn.remove(id)
                self.isOnline = true
                self.startSocket(url: url, auth: auth)
                if let libs = try? await client.libraries() {
                    guard self.activeConnectionID == id else { return }
                    try? self.cache.upsertLibraries(libs.enumerated().map { index, lib in
                        CachedLibrary(id: lib.id, connectionID: id, name: lib.name,
                                      mediaType: lib.mediaType, displayOrder: lib.displayOrder ?? index)
                    }, connectionID: id)
                }
            } catch ABSError.reauthRequired, ABSError.notAuthenticated {
                guard self.activeConnectionID == id else { return }
                self.isOnline = false
                self.needsSignIn.insert(id)
            } catch {
                // Host down / transport error: stay in cached-only offline mode. `isOnline ==
                // false` drives the offline banner; no blocking error alert for an expected
                // offline case.
                guard self.activeConnectionID == id else { return }
                self.isOnline = false
            }
        }
    }

    /// Signs out of a connection: retires the session if this connection OWNS it, tears down its
    /// socket if it's active, and clears its stored tokens — but KEEPS the connection row and all
    /// cached rows so the user can still browse offline and sign back in later. Marks it
    /// `needsSignIn` so `ConnectionsView` badges it and routes a tap to re-auth.
    func signOut(connectionID id: String) async {
        if playingConnectionID == id {
            await retireCurrentSession()
        }
        if activeConnectionID == id {
            stopSocket()
            isOnline = false
            client = nil
            auth = nil
        }
        await tokenStore.clear(for: id)
        needsSignIn.insert(id)
        loadConnections()
    }

    /// Forgets a connection entirely: sign-out semantics first (retire if it owns playback, stop
    /// the socket if active, clear the keychain entry), then purge every trace — the SQLite cache
    /// rows (connection + libraries + items + progress) in one transaction and the on-disk cover
    /// folder. If it was the active connection, drops back to a disconnected state so the boot
    /// flow re-routes to `ConnectionsView` (or `ConnectView` when none remain).
    func removeConnection(_ id: String) async {
        await signOut(connectionID: id)
        if activeConnectionID == id {
            activeConnectionID = nil
            client = nil
            auth = nil
            phase = .disconnected
        }
        if lastActiveConnectionID == id {
            lastActiveConnectionID = nil
            UserDefaults.standard.removeObject(forKey: Self.lastActiveConnectionIDKey)
        }
        needsSignIn.remove(id)
        try? cache.deleteConnection(connectionID: id)
        await coverStore.deleteConnection(connectionID: id)
        loadConnections()
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
    /// `internal` (not `private`) so the state-machine tests can drive it deterministically
    /// without waiting on the nondeterministic socket-consumer task.
    func apply(_ event: ServerEvent) async {
        guard let connectionID = activeConnectionID else { return }
        switch event {
        case .progressUpdated(let update):
            try? cache.upsertProgress(CachedProgress(
                connectionID: connectionID, itemID: update.itemID, episodeID: update.episodeID,
                currentTime: update.currentTime, isFinished: update.isFinished, lastUpdate: update.lastUpdate))
        case .progressBatch(let updates):
            let batch = updates.map { update in
                CachedProgress(
                    connectionID: connectionID, itemID: update.itemID, episodeID: update.episodeID,
                    currentTime: update.currentTime, isFinished: update.isFinished, lastUpdate: update.lastUpdate)
            }
            try? cache.upsertProgressBatch(batch)
        case .itemChanged, .itemsChanged:
            if let libraryID = activeLibraryID { try? await refreshItems(libraryID: libraryID) }
        case .itemRemoved(let id):
            // Precise deletion first (instant, no round trip) — the coarse re-page below is a
            // safety net for anything else the same event batch implies, not the primary path.
            try? cache.deleteItem(connectionID: connectionID, itemID: id)
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

    private func findOrCreateConnection(
        address: String, username: String, authMethod: String = "local"
    ) throws -> CachedConnection {
        if let existing = try cache.connections().first(where: {
            $0.address == address && $0.username == username
        }) {
            return existing
        }
        let fresh = CachedConnection(id: UUID().uuidString, address: address,
                                     name: URL(string: address)?.host() ?? address,
                                     username: username, authMethod: authMethod,
                                     sortIndex: try cache.connections().count)
        try cache.upsertConnection(fresh)
        return fresh
    }

    /// Pages `client.items` (50/page) into the cache until the server-reported total is
    /// satisfied or a 20-page (1000-item) cap is hit — a deliberate M1a limit; full unbounded
    /// paging is out of scope until it's needed.
    ///
    /// A completed page-through (every item seen, uncapped) reconciles via `replaceItems` so
    /// items the server no longer reports (deleted/moved libraries) disappear from the cache —
    /// otherwise a capped/interrupted page-through only upserts what it saw, exactly like before.
    ///
    /// On outright failure (network/server error), a library the cache already has content for
    /// gets a non-blocking `refreshBanner` instead of throwing — the existing (possibly stale)
    /// items stay on screen. A library the cache has nothing for still throws, preserving
    /// `LibraryItemsView`'s existing loadError/ContentUnavailableView path.
    func refreshItems(libraryID: String) async throws {
        guard let client, let connectionID = activeConnectionID else {
            throw ABSError.notAuthenticated
        }
        activeLibraryID = libraryID
        let limit = 50
        var accumulated: [CachedItem] = []
        var lastTotal = 0
        var completed = false
        do {
            for page in 0..<20 {
                let result = try await client.items(libraryID: libraryID, limit: limit, page: page)
                lastTotal = result.total
                accumulated += result.results.map { item in
                    CachedItem(id: item.id, connectionID: connectionID, libraryID: libraryID,
                              title: item.media.metadata.title ?? "Untitled",
                              authorName: item.media.metadata.authorName,
                              duration: item.media.duration, updatedAt: item.updatedAt)
                }
                if result.results.isEmpty || accumulated.count >= result.total {
                    completed = true
                    break
                }
            }
        } catch {
            if let existing = try? cache.items(connectionID: connectionID, libraryID: libraryID),
               !existing.isEmpty {
                refreshBanner = (libraryID: libraryID,
                                 message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
            throw error
        }
        if completed {
            // replaceItems with [] wipes the library's cache — only reached after a completed
            // page-through; guarded below so a lying/failed response that reports a non-zero
            // total but hands back zero items can never nuke a good cache.
            if !(lastTotal > 0 && accumulated.isEmpty) {
                try cache.replaceItems(accumulated, connectionID: connectionID, libraryID: libraryID)
            }
        } else {
            try cache.upsertItemsPage(accumulated, connectionID: connectionID, libraryID: libraryID)
        }
        // Success clears only this library's banner — another library's failure stays visible
        // on its own screen until *it* refreshes successfully.
        if refreshBanner?.libraryID == libraryID { refreshBanner = nil }
    }

    /// Retry hook for the `RefreshBanner`'s button — re-runs `refreshItems` for the library the
    /// banner belongs to (the view passes its own `library.id`, no `activeLibraryID` indirection).
    func retryRefresh(libraryID: String) {
        Task { try? await refreshItems(libraryID: libraryID) }
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
        playingConnectionID = nil
    }

    func startPlayback(itemID: String) async {
        // First-tap-wins reentrancy guard: without it, two rapid taps both pass
        // `retireCurrentSession` (handle nil) and both await `client.startPlayback`; if response
        // A lands after B, the user hears the wrong item and B's server session leaks open.
        guard !isStartingPlayback else { return }
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        guard let client else { return }
        // Captured NOW, before any await below — a connection switch racing the awaits (e.g.
        // during `retireCurrentSession`'s flush/close or `client.startPlayback`'s round trip)
        // must not be misattributed as this session's owner.
        let owner = activeConnectionID
        // Retire the old session completely before touching the new one.
        await retireCurrentSession()
        do {
            let envelope = try await client.startPlayback(itemID: itemID, deviceInfo: deviceInfo)
            let handle = PlaybackSessionHandle(client: client, envelope: envelope)
            sessionHandle = handle
            // Record which connection owns this session so signOut/remove of that connection
            // retires it first, while a mere connection *switch* leaves it playing (the handle
            // holds its own client, captured above — independent of `self.client`).
            playingConnectionID = owner
            playback.onSyncDue = { payload in
                await handle.sync(currentTime: payload.currentTime, timeListened: payload.timeListened)
            }
            let ordered = envelope.session.audioTracks.sorted { $0.startOffset < $1.startOffset }
            let urls = ordered.map { client.publicTrackURL(sessionID: envelope.session.id, trackIndex: $0.index) }
            // Set BEFORE `load()`: `load()` calls `NowPlayingUpdater.configure`, which reads
            // `playback.skipInterval` to advertise the lock-screen/remote-command skip intervals
            // — it must already hold this playback's value when that happens.
            playback.skipInterval = Self.storedSkipInterval()
            playback.load(session: envelope.session, trackURLs: urls)
            // Set AFTER `load()` (which resets the controller's session state) and BEFORE
            // `play()`: a freshly opened book starts at the user's default rate.
            playback.rate = Float(Self.storedDefaultRate())
            playback.play()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Scene backgrounding: flush accumulated listened-time WITHOUT pausing — background
    /// audio must keep playing (server-side 36h reaping + 404-recovery cover full termination).
    /// On iOS the flush runs inside a `UIBackgroundTaskIdentifier` assertion: without one, iOS is
    /// free to suspend the process mid-POST (this `Task` is detached — `ColophonApp`'s
    /// `scenePhase` observer doesn't/can't await it) and the tail of listened time never reaches
    /// the server. The expiration handler matters as much as the assertion itself: a background
    /// task that overruns the OS budget (~30s) WITHOUT one is terminated ungracefully, whereas
    /// ending it in the handler is a clean early release (the stalled POST is lost either way,
    /// but the process isn't killed for it). macOS has no app-suspension model; path unchanged.
    #if os(iOS)
    /// The live background-flush assertion, `.invalid` when none is held. An instance property
    /// rather than a captured local `var` because BOTH closures that must end it — the
    /// expiration handler and the flush `Task` — need shared mutable state, which strict
    /// concurrency forbids for a captured `var`; this property's MainActor isolation is the
    /// synchronization that makes the end-exactly-once guard sound.
    private var backgroundFlushTaskID: UIBackgroundTaskIdentifier = .invalid

    func flushForBackground() {
        // A fresh backgrounding supersedes any assertion still pending from the previous one.
        endBackgroundFlushTask()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "colophon.flush") { [weak self] in
            // Budget expired before the flush finished: release the assertion gracefully.
            self?.endBackgroundFlushTask()
        }
        backgroundFlushTaskID = taskID
        Task {
            await playback.flushOnly()
            // End only the assertion THIS flush owns: if expiration (or a newer backgrounding)
            // already released it, `backgroundFlushTaskID` no longer matches and this is a no-op
            // — never a double-end, never ending a successor's assertion.
            if backgroundFlushTaskID == taskID { endBackgroundFlushTask() }
        }
    }

    private func endBackgroundFlushTask() {
        guard backgroundFlushTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundFlushTaskID)
        backgroundFlushTaskID = .invalid
    }
    #else
    func flushForBackground() {
        Task { await playback.flushOnly() }
    }
    #endif

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
