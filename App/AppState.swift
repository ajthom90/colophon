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

/// The library-browse sort options surfaced in `LibraryGridView`'s toolbar, each mapped to a
/// verified ABS `items?sort=` key (see the plan's endpoint reference). Plain `Sendable` value type
/// (not MainActor-isolated) so it can travel into the client request off the main actor.
nonisolated enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case title, author, added, published, progress

    var id: String { rawValue }

    /// The exact `sort=` value ABS expects for this choice.
    var serverKey: String {
        switch self {
        case .title: return "media.metadata.title"
        case .author: return "media.metadata.authorName"
        case .added: return "addedAt"
        case .published: return "media.metadata.publishedYear"
        case .progress: return "progress"
        }
    }

    /// The human-facing menu label.
    var label: String {
        switch self {
        case .title: return "Title"
        case .author: return "Author"
        case .added: return "Date Added"
        case .published: return "Published Year"
        case .progress: return "Progress"
        }
    }
}

/// One active library filter, built from a `filterdata` facet selection. ABS wants the request
/// param `filter=<group>.<base64url(value)>` where — verified against the ABS filter convention —
/// the encoded value is the author/series *ID* for the `authors`/`series` groups and the plain
/// string for `genres`/`tags`/`narrators`/`languages`/`publishedDecades`. `displayValue` is what
/// the UI shows; `rawValue` is what gets base64url-encoded.
nonisolated struct LibraryFilter: Equatable, Hashable, Sendable {
    var group: String
    var displayValue: String
    var rawValue: String

    init(group: String, displayValue: String, rawValue: String) {
        self.group = group
        self.displayValue = displayValue
        self.rawValue = rawValue
    }

    /// The `<group>.<base64url(value)>` string threaded into `ABSClient.items(filter:)`.
    var queryValue: String { group + "." + Self.base64URLEncode(rawValue) }

    /// ABS filter convention: `Buffer.from(value).toString('base64')` made URL-safe — `+`→`-`,
    /// `/`→`_`, and `=` padding stripped. Node's `Buffer.from(x,'base64')` decodes this url-safe,
    /// unpadded form, so the server round-trips the original value.
    static func base64URLEncode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

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
    /// The item ID of the currently-playing session, surfaced so the navigation shell's
    /// `MiniPlayerBar`/`TransportBar` can render the right cover artwork. Set alongside
    /// `playingConnectionID` when `startPlayback` succeeds and cleared when the session is retired.
    /// Read-only to the UI (private setter).
    private(set) var nowPlayingItemID: String?
    /// Last library ID `refreshItems` was asked to page — recorded so a future first-run/
    /// offline flow (M1b) can resume browsing the last-viewed library without a live server.
    private(set) var activeLibraryID: String?

    // MARK: - Library browse (Task 8) — sort/filter state feeding refreshItems + the items request.

    /// The active grid sort key. Mutated by `LibraryGridView`'s toolbar; read by `refreshItems`
    /// to drive the server `items?sort=` query. Persists while browsing so a library re-visit
    /// keeps the user's chosen order.
    var librarySort: LibrarySort = .title
    /// Ascending (`false`) vs descending (`true`) for `librarySort` — the toolbar order toggle.
    var sortDescending = false
    /// The active facet filter (nil = unfiltered). Set from `FilterSheet`; drives `items?filter=`.
    /// Reset per-library on a library switch (a different library's facet IDs won't match).
    var libraryFilter: LibraryFilter?

    /// The server-authoritative item ORDER captured by the most recent successful `refreshItems`,
    /// keyed by libraryID. The cache's `observeItems` only knows title order, so the grid renders
    /// in THIS order (falling back to the cache's title order before the first refresh completes,
    /// for instant offline paint). When a filter is active this holds ONLY the matching item IDs,
    /// so the grid shows exactly the filtered set without the cache ever deleting non-matching rows.
    private(set) var libraryItemOrder: [String: [String]] = [:]

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
    /// Monotonic epoch capturing "the latest connection-mutating user intent" — the ONE
    /// authoritative "am I still the current intent?" guard. Every flow that mutates connection
    /// state (`connect`, `connectWithOIDC`, `activateConnection`, `signOut`, `removeConnection`)
    /// calls `beginConnectionFlow()` once it's committed to actually starting, capturing the
    /// returned `myEpoch`; after every `await` — and in the detached `probeTask` — it re-checks
    /// `connectionEpoch == myEpoch` before writing any shared state or standing up a socket, and
    /// bails if a newer flow has superseded it. It composes across all five flows where the per-flow
    /// guards (`phase`, `activatingConnectionID`, `activeConnectionID`) did not: it stops a
    /// slow/abandoned connect from clobbering a newer activation, stops an in-flight probe from
    /// resurrecting a connection the user just signed out of or removed, and stops an older
    /// `signOut`/`removeConnection` tail from stomping a newer activation started during its awaits.
    private var connectionEpoch = 0

    /// Opens a new connection epoch and returns it — the single entry point every connection-mutating
    /// flow calls exactly once, at the moment it commits to running (for `connect`/`connectWithOIDC`
    /// that is AFTER URL validation, so an invalid URL that returns early never stales a healthy
    /// active connection's in-flight probe). Callers capture the return as `myEpoch` and re-check
    /// `connectionEpoch == myEpoch` after every subsequent await.
    private func beginConnectionFlow() -> Int {
        connectionEpoch += 1
        return connectionEpoch
    }

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
        // Bump the epoch only NOW, once URL validation has passed and we're committed to starting a
        // connection flow. An invalid URL returns above WITHOUT bumping, so it never stales a healthy
        // active connection's in-flight probe (Asymmetry fix A).
        let myEpoch = beginConnectionFlow()
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
            // A newer flow (a fresh activation/connect, or a sign-out) superseded this connect
            // while `/status` was in flight: discard silently — the newer flow owns the state now.
            guard connectionEpoch == myEpoch else { return }
            try checkVersionGate(status)
            let connection = try findOrCreateConnection(address: url.absoluteString, username: username)
            // Awaited (not fire-and-forget) so migration can never race a fresh login's token
            // save — it must finish moving any legacy entry before `auth.login` writes new ones.
            await TokenMigration.migrateLegacyTokensIfNeeded(
                from: url.absoluteString, to: connection.id, store: tokenStore)
            guard connectionEpoch == myEpoch else { return }
            let auth = AuthManager(baseURL: url, connectionID: connection.id,
                                   transport: transport, store: tokenStore)
            _ = try await auth.login(username: username, password: password)
            // A stale connect whose (possibly minutes-long) login finally landed must NOT clobber
            // the connection a newer activation put in place. Its saved tokens are harmless —
            // keyed by this connection's own id — so just discard without touching shared state.
            guard connectionEpoch == myEpoch else { return }
            try await completeConnection(connection: connection, auth: auth, url: url, epoch: myEpoch)
        } catch ABSError.http(status: 401) {
            // Only surface the error / reset state if we're still the current intent — a stale
            // connect must not stopSocket a newer connection nor bounce the user out. If the
            // superseder was a signOut and `completeConnection` had already published (then threw),
            // the bail still clears the stranded publication.
            guard connectionEpoch == myEpoch else {
                clearStalePublicationIfDisconnected()
                return
            }
            stopSocket()
            phase = .disconnected
            activeConnectionID = nil   // no stale ID while disconnected
            errorMessage = "Wrong username or password"
        } catch {
            guard connectionEpoch == myEpoch else {
                clearStalePublicationIfDisconnected()
                return
            }
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
        // Bump only after the normalize/validate prefix, before the awaits — same Asymmetry-fix-A
        // reasoning as `connect()`: an invalid URL returns above without staling an active probe.
        let myEpoch = beginConnectionFlow()
        stopSocket()
        activeConnectionID = nil
        refreshBanner = nil
        phase = .connecting
        do {
            let transport = self.transport
            let status = try await ABSClient.status(baseURL: url, transport: transport)
            guard connectionEpoch == myEpoch else { return }
            try checkVersionGate(status)
            let flow = OIDCFlow(serverURL: url, transport: oidcTransport)
            // The browser hop can sit open for minutes; a newer activation/connect in that window
            // supersedes this one and its `myEpoch` will no longer match below.
            let loginResponse = try await flow.authenticate(browser: browser)
            guard connectionEpoch == myEpoch else { return }
            let connection = try findOrCreateConnection(
                address: url.absoluteString, username: loginResponse.user.username, authMethod: "openid")
            let auth = AuthManager(baseURL: url, connectionID: connection.id,
                                   transport: transport, store: tokenStore)
            try await auth.completeOIDC(loginResponse: loginResponse)
            guard connectionEpoch == myEpoch else { return }
            try await completeConnection(connection: connection, auth: auth, url: url, epoch: myEpoch)
        } catch {
            // A stale OIDC connect must not tear down or reset a newer connection's state — but
            // it does clear its own stranded publication if a signOut superseded it mid-tail.
            guard connectionEpoch == myEpoch else {
                clearStalePublicationIfDisconnected()
                return
            }
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
    private func completeConnection(connection: CachedConnection, auth: AuthManager, url: URL, epoch myEpoch: Int) async throws {
        let transport = self.transport
        let client = ABSClient(baseURL: url, transport: transport, auth: auth)
        self.auth = auth
        self.client = client
        self.activeConnectionID = connection.id
        let libs = try await client.libraries()
        // A newer flow superseded this connect while the library list was in flight — it owns
        // `activeConnectionID`/socket/phase now, so bail without stomping any of it (in particular
        // without `startSocket`, which would tear down the newer connection's live socket). One
        // cleanup IS ours to do: this method published `activeConnectionID`/`client`/`auth` above,
        // BEFORE the await. If the superseder was a signOut/removeConnection (which normalizes a
        // stranded `.connecting` to `.disconnected` but can't know this flow had already published),
        // those fields still point at the stale connection while disconnected — clear them so the
        // "no stale ID while disconnected" invariant holds. Scoped tightly to `.disconnected`
        // (see the helper's doc): a newer activation (`.connected`) or a newer in-flight connect
        // (`.connecting`, which republishes these fields itself) is left untouched.
        guard connectionEpoch == myEpoch else {
            clearStalePublicationIfDisconnected()
            return
        }
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

    /// Cleanup for a superseded (stale-epoch) connect flow's bail paths. `completeConnection`
    /// publishes `activeConnectionID`/`client`/`auth` BEFORE its `libraries()` await; if a
    /// signOut/removeConnection supersedes during that await (normalizing a stranded `.connecting`
    /// to `.disconnected` — it can't know this flow had already published), the stale bail — the
    /// in-method guard on a 200, or the caller's catch guard on a throw — would otherwise leave
    /// those fields pointing at the stale connection while disconnected. Scoped tightly to
    /// `.disconnected`: a newer activation (`.connected`) or a newer in-flight connect
    /// (`.connecting`, which republishes these fields itself) owns them and is left untouched;
    /// `.disconnected` provably never coexists with another flow's live publication (every path
    /// that sets it nils `activeConnectionID`, except this stranding).
    private func clearStalePublicationIfDisconnected() {
        guard phase == .disconnected else { return }
        activeConnectionID = nil
        client = nil
        auth = nil
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
        // Open the epoch AFTER the same-id reentrancy guard above: a reentrant same-id call bails
        // without opening one, so it can't invalidate the first (still legitimate) activation's own
        // probe. This minimal same-id guard is retained (folding it into the epoch can't replace it:
        // a same-id double-tap must bail synchronously, before the token-store await, or it would
        // build a second `AuthManager`/`ABSClient` and probe — see `activateConnectionReentrancyGuard`).
        let myEpoch = beginConnectionFlow()

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
            // The token lookup is a real suspension point — a newer flow may have superseded us
            // while it was in flight; if so, leave its state alone.
            guard connectionEpoch == myEpoch else { return }
            client = nil
            auth = nil
            needsSignIn.insert(id)
            return
        }
        guard connectionEpoch == myEpoch else { return }
        let auth = AuthManager(baseURL: url, connectionID: id, transport: transport, store: tokenStore)
        let client = ABSClient(baseURL: url, transport: transport, auth: auth)
        self.auth = auth
        self.client = client

        // The network probe: detached so `activateConnection` returns now, with cached browsing
        // already live. Every branch re-checks the epoch (authoritative — a sign-out/removal
        // or a newer activation of this or another id supersedes this probe) plus `activeConnectionID
        // == id` for id-specificity, since either an in-flight `authorize()` or the `libraries()`
        // that follows can resume long after the user has moved on. A signed-out connection leaves
        // `activeConnectionID == id`, so without the epoch check the probe would RESURRECT it
        // (needsSignIn.remove, isOnline, socket) for a connection the user just abandoned.
        probeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.authorize()
                guard self.connectionEpoch == myEpoch, self.activeConnectionID == id else { return }
                self.needsSignIn.remove(id)
                self.isOnline = true
                self.startSocket(url: url, auth: auth)
                if let libs = try? await client.libraries() {
                    guard self.connectionEpoch == myEpoch, self.activeConnectionID == id else { return }
                    try? self.cache.upsertLibraries(libs.enumerated().map { index, lib in
                        CachedLibrary(id: lib.id, connectionID: id, name: lib.name,
                                      mediaType: lib.mediaType, displayOrder: lib.displayOrder ?? index)
                    }, connectionID: id)
                }
            } catch ABSError.reauthRequired, ABSError.notAuthenticated {
                guard self.connectionEpoch == myEpoch, self.activeConnectionID == id else { return }
                self.isOnline = false
                self.needsSignIn.insert(id)
            } catch {
                // Host down / transport error: stay in cached-only offline mode. `isOnline ==
                // false` drives the offline banner; no blocking error alert for an expected
                // offline case.
                guard self.connectionEpoch == myEpoch, self.activeConnectionID == id else { return }
                self.isOnline = false
            }
        }
    }

    /// Signs out of a connection: retires the session if this connection OWNS it, tears down its
    /// socket if it's active, and clears its stored tokens — but KEEPS the connection row and all
    /// cached rows so the user can still browse offline and sign back in later. Marks it
    /// `needsSignIn` so `ConnectionsView` badges it and routes a tap to re-auth.
    func signOut(connectionID id: String) async {
        await performSignOut(connectionID: id, epoch: beginConnectionFlow())
    }

    /// The sign-out body, run under a caller-owned epoch so `removeConnection` can share ONE epoch
    /// across its whole flow (it opens the epoch, runs this, then guards its own tail on the same
    /// value). Opening the epoch FIRST, before any await: an in-flight `activateConnection` probe for
    /// THIS connection (parked in `authorize()`/`libraries()`) captured the previous epoch, so this
    /// immediately makes it stale — when it resumes it will no-op instead of resurrecting the
    /// connection we're signing out (needsSignIn.remove + isOnline + socket for a dead session).
    private func performSignOut(connectionID id: String, epoch myEpoch: Int) async {
        // Opening the epoch also makes any in-flight connect/connectWithOIDC bail at its epoch guards
        // — INCLUDING the catch blocks that normally reset `phase` — so a connect mid-flight right
        // now would otherwise strand `phase == .connecting` forever, and both connect entry guards
        // (`guard phase != .connecting`) would refuse every future sign-in. Normalize it here: the
        // superseded connect then bails harmlessly against an already-reset phase. Conditional so
        // signing out an inactive row while CONNECTED leaves the current browsing session alone.
        // `removeConnection` inherits this uniformly — its first step is this method.
        if phase == .connecting { phase = .disconnected }
        if playingConnectionID == id {
            await retireCurrentSession()
        }
        // Active-state teardown is guarded on the epoch, not just `activeConnectionID == id`
        // (Asymmetry fix B): a newer activation started during retire's flush/close round-trips —
        // even a re-activation of THIS same id, which `activeConnectionID == id` alone can't
        // distinguish — now owns the live socket/client, so this older sign-out must not stomp it.
        // The id-scoped bookkeeping below (clear tokens, badge, reload) still runs unconditionally
        // so the signed-out row is genuinely signed out regardless of who is active now.
        if connectionEpoch == myEpoch, activeConnectionID == id {
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
        // Open ONE epoch for the whole remove flow and thread it through the shared sign-out body,
        // so this method and its inner sign-out agree on a single "am I still the latest intent"
        // value (rather than the sign-out opening one this method can't see). Epoch open AND
        // `.connecting`-phase normalization both happen inside `performSignOut` (unconditionally,
        // before its first await), so every removeConnection path — active or inactive row — leaves
        // `phase` definite; the branch below only additionally drops a previously-CONNECTED active
        // row to `.disconnected`.
        let myEpoch = beginConnectionFlow()
        await performSignOut(connectionID: id, epoch: myEpoch)
        // Same Asymmetry-fix-B guard as the sign-out body: only clear the active session down to
        // `.disconnected` if we're STILL the latest intent — a newer activation during the awaits
        // above (its probe, retire, or `tokenStore.clear`) owns `activeConnectionID`/`phase` now.
        if connectionEpoch == myEpoch, activeConnectionID == id {
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

    /// Upper bound on how many ids one `items_updated`/`items_added` batch will patch one-by-one
    /// before falling back to a single full-library `refreshItems`: past this, N single-item
    /// round trips cost more than one paged reconcile (and a mass edit is exactly the case a
    /// reconcile handles cleanly).
    private static let itemsChangedPatchBound = 50

    /// Applies a decoded server event to local state. `progressUpdated`/`progressBatch` upsert
    /// straight into the cache (last-write-wins by `lastUpdate`, enforced in
    /// `LibraryCacheStore.upsertProgress`). `itemChanged`/`itemsChanged` do a TARGETED per-item
    /// patch (`patchItem` → one-row upsert) rather than a coarse full-library re-page — a large
    /// `itemsChanged` batch (> `itemsChangedPatchBound`) is the one case that still falls back to
    /// a single `refreshItems`. `itemRemoved` stays the precise-delete deletion path.
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
        case .itemChanged(let id):
            try? await patchItem(id: id, connectionID: connectionID)
        case .itemsChanged(let ids):
            // A huge batch (a bulk metadata edit / mass import) is cheaper — and more correct —
            // to reconcile in one paged pass than to fire N single-item fetches.
            if ids.count > Self.itemsChangedPatchBound {
                if let libraryID = activeLibraryID { try? await refreshItems(libraryID: libraryID) }
            } else {
                for id in ids { try? await patchItem(id: id, connectionID: connectionID) }
            }
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

    /// Generous upper bound on how many pages `refreshItems` will fetch before it gives up on
    /// completing a full page-through: 200 pages × 50/page ≈ 10 000 items. The M1a hard 20-page
    /// (1000-item) cap is GONE — a capped page-through never called `replaceItems`, so any
    /// library over 1000 items accreted ghost rows forever (deleted items were never reconciled
    /// away). This bound only exists so a pathological giant library degrades gracefully
    /// (per-page upsert, no reconcile) rather than paging without end; a normal library of any
    /// realistic size pages to completion and reconciles.
    private static let refreshPageSafetyBound = 200

    /// Pages `client.items` (50/page) into the cache until the server-reported total is satisfied
    /// (`accumulated.count >= total`) — the ghost-accretion hazard is closed: a COMPLETED
    /// page-through reconciles via `replaceItems`, so items the server no longer reports
    /// (deleted/moved) disappear from the cache for a library of ANY size.
    ///
    /// The only ceiling is `refreshPageSafetyBound` (≈10k items): if a library is so large the
    /// loop hits it WITHOUT completing, we degrade to a plain per-page `upsertItemsPage` and skip
    /// `replaceItems` — a giant library keeps its rows (no accidental wipe from an incomplete
    /// view) rather than paging forever. The lying-response guard (`total > 0` but zero items
    /// accumulated → skip `replaceItems`) still protects a completed-but-empty response from
    /// nuking a good cache.
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
        // Snapshot the browse state once so a mid-refresh toolbar change can't split the query
        // (page 0 filtered, page 1 not) — the next task-driven refresh picks up the new state.
        let sort = librarySort
        let desc = sortDescending
        let activeFilter = libraryFilter
        let limit = 50
        var accumulated: [CachedItem] = []
        var lastTotal = 0
        var completed = false
        do {
            for page in 0..<Self.refreshPageSafetyBound {
                let result = try await client.items(
                    libraryID: libraryID, limit: limit, page: page,
                    sort: sort.serverKey, desc: desc, filter: activeFilter?.queryValue)
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
        // A server "lie": a non-zero total but zero items handed back — never reconcile/wipe on it.
        let isLyingEmpty = (lastTotal > 0 && accumulated.isEmpty)
        if !completed {
            // Safety bound hit before the total was satisfied — a pathological (>~10k-item)
            // library. Note it and degrade to a plain upsert of what we DID page: never
            // `replaceItems`, which would delete every row past the bound we simply never fetched.
            NSLog("[Colophon] refreshItems: library \(libraryID) exceeded the \(Self.refreshPageSafetyBound)-page safety bound (total \(lastTotal)); upserting \(accumulated.count) paged items without reconciliation.")
            try cache.upsertItemsPage(accumulated, connectionID: connectionID, libraryID: libraryID)
        } else if activeFilter != nil {
            // Filtered page-through: the server returned ONLY matching items. `replaceItems` would
            // delete every non-matching cached row (destroying the offline browse set for a
            // transient filter); upsert instead so the matches are fresh, and let `libraryItemOrder`
            // below scope the grid's visible set to exactly these IDs.
            try cache.upsertItemsPage(accumulated, connectionID: connectionID, libraryID: libraryID)
        } else if !isLyingEmpty {
            // Completed, UNFILTERED page-through: reconcile. `replaceItems` with [] wipes the
            // library's cache — reached only for a genuinely empty library (total 0); the guard
            // above skips it for a lying/failed response, so that can never nuke a good cache.
            try cache.replaceItems(accumulated, connectionID: connectionID, libraryID: libraryID)
        }
        // Capture the server-authoritative order (full set unfiltered, matching set filtered) for
        // the grid — but never clobber a good order with a lying-empty response's zero IDs, and
        // never settle the grid on a SUPERSEDED order: if the sort/order/filter changed while this
        // (possibly slow) request was in flight, a newer refresh owns the order, so skip the write
        // and let it win. (Cache writes above are always safe — upsert or full reconcile of valid
        // rows — so only the order, which drives what the grid shows, needs this guard.)
        let stillCurrent = (librarySort == sort && sortDescending == desc && libraryFilter == activeFilter)
        if !isLyingEmpty && stillCurrent && !Task.isCancelled {
            libraryItemOrder[libraryID] = accumulated.map(\.id)
        }
        // Success clears only this library's banner — another library's failure stays visible
        // on its own screen until *it* refreshes successfully.
        if refreshBanner?.libraryID == libraryID { refreshBanner = nil }
    }

    /// Targeted single-item patch for `item_updated`/`item_added` socket events: fetches just
    /// that item (`GET /api/items/:id?expanded=1`), maps it to a `CachedItem`, and upserts the
    /// ONE row — no coarse full-library re-page. The item's own `libraryId` from the response
    /// scopes the upsert; a malformed/absent one falls back to `activeLibraryID` (the library the
    /// user is currently browsing — the only other context we have). If neither is available
    /// there's no library to scope the row to, so it's dropped (the next full `refreshItems`
    /// picks it up). Best-effort: a fetch/map failure is swallowed by the `try?` at the call site.
    private func patchItem(id: String, connectionID: String) async throws {
        guard let client else { return }
        let detail = try await client.item(id: id)
        guard let libraryID = detail.libraryId ?? activeLibraryID else { return }
        let item = CachedItem(
            id: detail.id, connectionID: connectionID, libraryID: libraryID,
            title: detail.media.metadata.title ?? "Untitled",
            authorName: detail.media.metadata.authorName,
            duration: detail.media.duration, updatedAt: detail.updatedAt)
        try cache.upsertItemsPage([item], connectionID: connectionID, libraryID: libraryID)
    }

    /// Retry hook for the `RefreshBanner`'s button — re-runs `refreshItems` for the library the
    /// banner belongs to (the view passes its own `library.id`, no `activeLibraryID` indirection).
    func retryRefresh(libraryID: String) {
        Task { try? await refreshItems(libraryID: libraryID) }
    }

    /// Joins `GET /api/me`'s `mediaProgress[]` into the cache's `CachedProgress` — THE source of
    /// the home shelves' progress pills, since personalized-shelf entities carry NO progress field
    /// (verified live). `HomeView` calls this on appear and on pull-to-refresh; from the connected
    /// shell's perspective that is "on connect/activate" (Home is the initial surface) plus every
    /// manual refresh. Deliberately NOT wired into `completeConnection`/`activateConnection`: those
    /// flows are covered by a FIFO-ordered `MockTransport` test suite that asserts exact request
    /// sequences, and a background `me()` there would perturb every connect-based test — so the
    /// join is driven from the UI lifecycle instead, which is where the pill is actually consumed.
    ///
    /// Best-effort: an absent/failed `me()` leaves existing progress untouched. The upsert is
    /// last-write-wins by `lastUpdate` (`upsertProgressBatch`), so a socket `progressUpdated` that
    /// lands before or after this join never regresses the newer value; `me()` entries carry the
    /// server's own `lastUpdate`, falling back to wall-clock only when the server omits it.
    func refreshProgress() async {
        guard let client, let connectionID = activeConnectionID else { return }
        guard let me = try? await client.me() else { return }
        // A connection switch during the me() round-trip must never write server-A progress under
        // server-B's ID.
        guard connectionID == activeConnectionID else { return }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let batch = (me.mediaProgress ?? []).map { entry in
            CachedProgress(
                connectionID: connectionID,
                itemID: entry.libraryItemId,
                episodeID: entry.episodeId,           // nil → "" per the 3-part PK
                currentTime: entry.currentTime ?? 0,
                isFinished: entry.isFinished ?? false,
                lastUpdate: entry.lastUpdate ?? now)
        }
        try? cache.upsertProgressBatch(batch)
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
        nowPlayingItemID = nil
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
            nowPlayingItemID = itemID
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
