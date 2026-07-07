import Testing
import Foundation
import AuthenticationServices
import ABSKit
import ABSKitTestSupport
import ABSRealtime
import LibraryCache
@testable import Colophon

/// State-machine coverage for `AppState` — where both M1a merge-gating bugs lived. Every test
/// runs fully offline: a `MockTransport`/`GatedTransport` for HTTP, an `InMemoryTokenStore`
/// (never the entitlement-bound Keychain), a temp-dir cache, and a `FakeSocket`.
@MainActor
struct AppStateTests {
    // MARK: - Fixtures

    let statusOK = #"{"isInit":true,"serverVersion":"2.35.1","authMethods":["local"]}"#
    let loginOK = #"{"user":{"id":"u1","username":"root","accessToken":"acc1","refreshToken":"ref1"}}"#
    let librariesOK = #"{"libraries":[{"id":"lib1","name":"Books","mediaType":"book","icon":null,"displayOrder":0}]}"#

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    /// The three responses a happy-path `connect()` consumes, in order.
    private func enqueueSuccessfulConnect(_ transport: MockTransport) async {
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 200, json: loginOK)
        await transport.enqueue(status: 200, json: librariesOK)
    }

    private func makeApp(
        transportProvider: @escaping @Sendable () -> Transport,
        dir: URL
    ) -> AppState {
        AppState(
            transportProvider: transportProvider,
            cacheDirectory: dir,
            socketFactory: { _, _ in FakeSocket() },
            tokenStore: InMemoryTokenStore(),
            // Same transport instance as `/status`/`/libraries` — lets a single MockTransport/
            // GatedTransport FIFO queue script an entire `connectWithOIDC` call in test order.
            oidcTransportProvider: transportProvider
        )
    }

    // MARK: - Tests

    /// A server older than the 2.26.0 floor is rejected at the version gate — before any login
    /// is attempted — with a message naming the required version.
    @Test func oldServerIsGated() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: #"{"isInit":true,"serverVersion":"2.20.0","authMethods":["local"]}"#)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")

        #expect(app.phase == .disconnected)
        #expect(app.errorMessage?.contains("2.26.0") == true)
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.contains("/status") })
        #expect(!paths.contains { $0.contains("/login") })
    }

    /// A second `connect()` fired while the first is still `.connecting` must bail at the
    /// reentrancy guard — the first `/status` stays the only one recorded.
    @Test func connectReentrancyGuard() async throws {
        let transport = GatedTransport(gatePath: "/status")
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        let first = Task { await app.connect(serverURL: "http://s:13378", username: "root", password: "pw") }
        // The first connect has now recorded /status and is parked on the gate (phase == .connecting).
        while await transport.requestCount(pathContains: "/status") == 0 { await Task.yield() }

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        #expect(await transport.requestCount(pathContains: "/status") == 1)

        await transport.openGate()
        await first.value
        #expect(await transport.requestCount(pathContains: "/status") == 1)
    }

    /// Two rapid play taps: the first-tap-wins guard drops the second while the first `/play`
    /// is in-flight, so exactly one `/play` request reaches the server.
    @Test func startPlaybackFirstTapWins() async throws {
        let transport = GatedTransport(gatePath: "/play")
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 200, json: loginOK)
        await transport.enqueue(status: 200, json: librariesOK)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)

        let first = Task { await app.startPlayback(itemID: "i1") }
        // The first tap's /play is now in-flight (parked on the gate, guard held).
        while await transport.requestCount(pathContains: "/play") == 0 { await Task.yield() }

        await app.startPlayback(itemID: "i2")
        #expect(await transport.requestCount(pathContains: "/play") == 1)

        await transport.openGate()
        await first.value
        #expect(await transport.requestCount(pathContains: "/play") == 1)
    }

    /// The same server typed two ways ("http://S:13378" vs "http://s:13378/") for the same user
    /// resolves to a single `CachedConnection` row — even across a simulated relaunch (a new
    /// `AppState` over the same cache dir).
    @Test func findOrCreateConnectionReuses() async throws {
        let dir = makeTempDir()

        let t1 = MockTransport()
        await enqueueSuccessfulConnect(t1)
        let app1 = makeApp(transportProvider: { t1 }, dir: dir)
        await app1.connect(serverURL: "http://S:13378", username: "root", password: "pw")
        #expect(app1.phase == .connected)

        let t2 = MockTransport()
        await enqueueSuccessfulConnect(t2)
        let app2 = makeApp(transportProvider: { t2 }, dir: dir)
        await app2.connect(serverURL: "http://s:13378/", username: "root", password: "pw")
        #expect(app2.phase == .connected)

        #expect(try app2.cache.connections().count == 1)
    }

    /// A 401 on login leaves no stale state: disconnected, no active connection, message set.
    @Test func failedLoginResetsState() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 401, json: "{}")
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "wrong")

        #expect(app.phase == .disconnected)
        #expect(app.activeConnectionID == nil)
        #expect(app.errorMessage != nil)
    }

    /// A `progressBatch` event upserts every update into the (temp) cache store.
    @Test func progressBatchLandsInCache() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)

        await app.apply(.progressBatch([
            ProgressUpdate(itemID: "i1", episodeID: nil, currentTime: 11, isFinished: false, lastUpdate: 100),
            ProgressUpdate(itemID: "i2", episodeID: nil, currentTime: 22, isFinished: true, lastUpdate: 200),
        ]))

        #expect(try app.cache.progress(connectionID: cid, itemID: "i1")?.currentTime == 11)
        #expect(try app.cache.progress(connectionID: cid, itemID: "i2")?.currentTime == 22)
    }

    /// `apply(.itemRemoved)` deletes the cached row directly (no round trip needed since
    /// `activeLibraryID` is unset here — the coarse-refresh fallback never fires).
    @Test func itemRemovedDeletes() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "i1", connectionID: cid, libraryID: "lib1", title: "Doomed",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")

        await app.apply(.itemRemoved(id: "i1"))

        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").isEmpty)
    }

    /// `apply(.itemRemoved)` with a library open (`activeLibraryID` set): the precise delete
    /// happens AND the coarse re-page fires — the `/items` request is actually made, and the
    /// removed row stays gone because the served page no longer contains it.
    @Test func itemRemovedDeletesAndCoarseRefreshesOpenLibrary() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        // Open lib1 (sets activeLibraryID) with a completed page containing both items.
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 2, results: ["doomed", "keep"]))
        try await app.refreshItems(libraryID: "lib1")
        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").count == 2)
        // The coarse-refresh page the removal event will trigger — "doomed" is absent.
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 1, results: ["keep"]))

        await app.apply(.itemRemoved(id: "doomed"))

        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").map(\.id) == ["keep"])
        let itemsRequests = await transport.recorded.filter { ($0.url?.path ?? "").contains("/items") }
        #expect(itemsRequests.count == 2)   // the open + the event-driven coarse refresh
    }

    /// The JSON shape `client.items` decodes — mirrors `ABSKitTests/Fixtures/items_page.json`,
    /// trimmed to just the fields `refreshItems` maps into `CachedItem`.
    private func itemsPageJSON(total: Int, results: [String] = []) -> String {
        let entries = results.map { entryID in
            #"{"id":"\#(entryID)","updatedAt":1,"media":{"duration":10,"metadata":{"title":"Fresh \#(entryID)","authorName":null}}}"#
        }.joined(separator: ",")
        return #"{"results":[\#(entries)],"total":\#(total),"limit":50,"page":0}"#
    }

    /// A `refreshItems` failure (transport has nothing queued for `/items`, so `MockTransport`
    /// throws) surfaces as a non-blocking `refreshBanner` — not `errorMessage` — when the cache
    /// already has rows for that library, and those rows are left untouched. The banner carries
    /// the failing library's ID.
    @Test func refreshFailureWithCachedItemsSetsBanner() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "i1", connectionID: cid, libraryID: "lib1", title: "Cached",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")

        try await app.refreshItems(libraryID: "lib1")

        #expect(app.refreshBanner?.libraryID == "lib1")
        #expect(app.refreshBanner?.message.isEmpty == false)
        #expect(app.errorMessage == nil)
        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").count == 1)
    }

    /// The banner is tagged with the library that actually failed: fail library B's refresh and
    /// the banner's `libraryID` is B — a `LibraryItemsView` for library A (which matches on
    /// `banner.libraryID == library.id`) would not show it.
    @Test func bannerIsScopedToFailingLibrary() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        // Both libraries have cached content; only libB's refresh fails (nothing queued).
        try app.cache.upsertItemsPage(
            [CachedItem(id: "a1", connectionID: cid, libraryID: "libA", title: "A",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "libA")
        try app.cache.upsertItemsPage(
            [CachedItem(id: "b1", connectionID: cid, libraryID: "libB", title: "B",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "libB")

        try await app.refreshItems(libraryID: "libB")

        #expect(app.refreshBanner?.libraryID == "libB")
        #expect(app.refreshBanner?.libraryID != "libA")
    }

    /// A completed (uncapped) page-through reconciles: a full single page whose `results` no
    /// longer includes a previously-cached item makes that item's row disappear.
    @Test func completedRefreshReconciles() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "stale", connectionID: cid, libraryID: "lib1", title: "Stale",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 1, results: ["i1"]))

        try await app.refreshItems(libraryID: "lib1")

        let items = try app.cache.items(connectionID: cid, libraryID: "lib1")
        #expect(items.map(\.id) == ["i1"])
    }

    /// A completed page-through that reports a non-zero total but hands back zero items (a
    /// lying/broken response) must NOT wipe the cache — the guard in `refreshItems` skips
    /// `replaceItems` entirely in that case.
    @Test func emptyResultWithNonZeroTotalDoesNotWipe() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "i1", connectionID: cid, libraryID: "lib1", title: "Kept",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 5, results: []))

        try await app.refreshItems(libraryID: "lib1")

        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").count == 1)
    }

    // MARK: - Connections (Task 8)

    /// The `PlaybackSession` shape `startPlayback` decodes — one track, no chapters.
    private let playSessionJSON = #"""
    {"id":"sess1","libraryItemId":"i1","episodeId":null,"displayTitle":"Book","displayAuthor":"Auth","duration":100,"startTime":0,"currentTime":0,"playMethod":0,"audioTracks":[{"index":1,"startOffset":0,"duration":100,"title":null,"contentUrl":"/x","mimeType":"audio/mpeg"}],"chapters":[]}
    """#

    private func makeApp(dir: URL, transport: Transport, tokenStore: any TokenStore) -> AppState {
        AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in FakeSocket() },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport })
    }

    /// THE offline first-run fix: activating a connection whose server is unreachable (transport
    /// has nothing queued, so the `POST /api/authorize` probe throws like a dead host) still lands
    /// `phase == .connected` with `isOnline == false`, and the connection's cached libraries stay
    /// observable straight from the temp store. It's offline, not a re-auth prompt.
    @Test func activateServesCachedRowsOffline() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()           // nothing queued → probe fails like a dead host
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: dir, transport: transport, tokenStore: tokenStore)
        // Seed a connection + cached library + stored tokens directly, simulating a prior session.
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try app.cache.upsertLibraries([CachedLibrary(id: "L1", connectionID: "C1", name: "Books",
                                                     mediaType: "book", displayOrder: 0)], connectionID: "C1")
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")

        await app.activateConnection("C1")

        #expect(app.phase == .connected)
        #expect(app.isOnline == false)
        #expect(app.activeConnectionID == "C1")
        #expect(!app.needsSignIn.contains("C1"))          // offline, not a rejected credential
        #expect(app.lastActiveConnectionID == "C1")       // persisted for next launch's auto-resume
        var iterator = app.cache.observeLibraries(connectionID: "C1").makeAsyncIterator()
        let libs = try await iterator.next()
        #expect(libs?.map(\.id) == ["L1"])                // cached libraries observable, server or not
    }

    /// Activating a connection with NO stored tokens skips the probe entirely and marks it
    /// `needsSignIn` — the row `ConnectionsView` badges and routes to re-auth — while still
    /// exposing its cached rows (phase connected, offline).
    @Test func activateWithoutTokensNeedsSignIn() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))

        await app.activateConnection("C1")

        #expect(app.phase == .connected)
        #expect(app.isOnline == false)
        #expect(app.needsSignIn.contains("C1"))
        // No token means no probe: not a single request was made.
        #expect(await transport.recorded.isEmpty)
    }

    /// Playback policy (Global Constraints): switching the active connection mid-listen does NOT
    /// touch the player. Connect A + play, switch to B, and playback keeps running — the session's
    /// `PlaybackSessionHandle` owns its own client, independent of the now-swapped `self.client`.
    @Test func switchingConnectionKeepsPlayback() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play for A
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)
        let ownerID = try #require(app.activeConnectionID)
        await app.startPlayback(itemID: "i1")
        #expect(app.playback.isPlaying == true)

        // A second connection exists in the cache; switch to it (no tokens → offline, no probe).
        try app.cache.upsertConnection(CachedConnection(id: "B", address: "http://b:13378", name: "B",
                                                        username: "root", authMethod: "local", sortIndex: 1))
        await app.activateConnection("B")

        #expect(app.activeConnectionID == "B")
        #expect(ownerID != "B")
        #expect(app.playback.isPlaying == true)           // the switch left the player alone
    }

    /// Signing out of the connection that OWNS the playing session retires it first: the `/play`
    /// that opened the session is followed by a `/close` that tears it down server-side.
    @Test func signOutOfOwnerRetiresSession() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play
        await transport.enqueue(status: 200, json: "{}")              // possible flush /sync
        await transport.enqueue(status: 200, json: "{}")              // /close
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: dir, transport: transport, tokenStore: tokenStore)
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        await app.startPlayback(itemID: "i1")
        #expect(app.playback.isPlaying == true)

        await app.signOut(connectionID: cid)

        let paths = await transport.recorded.compactMap { $0.url?.path }
        let playIdx = paths.firstIndex { $0.contains("/play") }
        let closeIdx = paths.firstIndex { $0.contains("/close") }
        #expect(playIdx != nil)
        #expect(closeIdx != nil)
        if let p = playIdx, let c = closeIdx { #expect(p < c) }       // retired: play, then close
        #expect(app.needsSignIn.contains(cid))
        #expect(app.isOnline == false)
        #expect(await tokenStore.tokens(for: cid) == nil)             // tokens cleared
        #expect(try app.cache.connections().count == 1)               // but the row + cache stay
    }

    /// Removing a connection purges every trace: its cache rows (connection/library/item/progress)
    /// and its keychain tokens are gone, and the active state drops to disconnected.
    @Test func removePurgesCacheAndTokens() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: dir, transport: transport, tokenStore: tokenStore)

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "i1", connectionID: cid, libraryID: "lib1", title: "Doomed",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        #expect(await tokenStore.tokens(for: cid) != nil)

        await app.removeConnection(cid)

        #expect(try app.cache.connections().isEmpty)
        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").isEmpty)
        #expect(app.connections.isEmpty)
        #expect(app.activeConnectionID == nil)
        #expect(app.phase == .disconnected)
        #expect(await tokenStore.tokens(for: cid) == nil)
    }

    // MARK: - Connections (Fix round 2)

    /// A double-tap on the same connection row — two `activateConnection` calls for the SAME id
    /// overlapping before the first's (now fast) synchronous section finishes — must not stand up
    /// two live sockets. `GatedTokenStore` parks the first call's one real suspension point (the
    /// actor-hop into `tokens(for:)`) so the second call deterministically lands on the
    /// `activatingConnectionID` guard instead of racing on wall-clock timing.
    @Test func activateConnectionReentrancyGuard() async throws {
        final class SocketConstructionCounter { private(set) var count = 0; func record() { count += 1 } }

        let dir = makeTempDir()
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: "{}")   // the surviving call's /api/authorize
        let tokenStore = GatedTokenStore()
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")
        let sockets = SocketConstructionCounter()
        let app = AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in sockets.record(); return FakeSocket() },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport }
        )
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))

        let first = Task { await app.activateConnection("C1") }
        // The first call is parked on the gated token lookup — its synchronous section (and the
        // `activatingConnectionID` guard it holds) hasn't returned yet.
        while await tokenStore.waitingCount == 0 { await Task.yield() }

        await app.activateConnection("C1")   // must bail at the reentrancy guard — a same-id no-op

        await tokenStore.openGate()
        await first.value
        // Let the surviving call's detached probe run to completion (it calls `startSocket`).
        while !app.isOnline { await Task.yield() }

        #expect(sockets.count == 1)          // exactly one socket ever constructed — no leak
    }

    /// `activateConnection` no longer blocks on the network: with `/api/authorize` hung on a
    /// gate, the call still returns promptly with cached browsing already live — `isOnline` stays
    /// false and the connection's cached libraries are observable — while the probe is still
    /// pending in the background.
    @Test func activateReturnsBeforeProbeCompletes() async throws {
        let dir = makeTempDir()
        let transport = GatedTransport(gatePath: "/api/authorize")
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: dir, transport: transport, tokenStore: tokenStore)
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try app.cache.upsertLibraries([CachedLibrary(id: "L1", connectionID: "C1", name: "Books",
                                                     mediaType: "book", displayOrder: 0)], connectionID: "C1")
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")

        await app.activateConnection("C1")   // returns even though the probe is parked on the gate

        #expect(app.phase == .connected)
        #expect(app.isOnline == false)                    // the probe hasn't resolved yet
        var iterator = app.cache.observeLibraries(connectionID: "C1").makeAsyncIterator()
        let libs = try await iterator.next()
        #expect(libs?.map(\.id) == ["L1"])                // cached rows observable while it hangs

        // Let the probe resolve so it doesn't leak a permanently-parked continuation past the test.
        await transport.enqueue(status: 200, json: "{}")
        await transport.openGate()
        while !app.isOnline { await Task.yield() }
    }

    // MARK: - Connection generation token (final-review fix batch)

    /// Race A — a probe must not RESURRECT a signed-out connection. Activate `C1` with its
    /// `authorize()` parked on a `GatedTransport`; while the probe hangs, `signOut(C1)` (which
    /// deliberately leaves `activeConnectionID == C1`, the old guard's blind spot). Release the
    /// gate: `authorize()` returns 200, but the connection-generation bump `signOut` performed
    /// makes the resumed probe stale, so it no-ops — it must NOT flip `isOnline`, clear the
    /// needs-sign-in mark, or build a socket for the connection the user just abandoned.
    @Test func signOutCancelsInFlightProbe() async throws {
        final class SocketConstructionCounter { private(set) var count = 0; func record() { count += 1 } }

        let dir = makeTempDir()
        let transport = GatedTransport(gatePath: "/api/authorize")   // park the probe mid-authorize
        let tokenStore = InMemoryTokenStore()
        let sockets = SocketConstructionCounter()
        let app = AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in sockets.record(); return FakeSocket() },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport }
        )
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")

        await app.activateConnection("C1")        // returns; the probe is launched and parks on the gate
        // Ensure the probe has actually reached (and is suspended at) the /api/authorize send.
        while await transport.requestCount(pathContains: "/api/authorize") == 0 { await Task.yield() }
        #expect(app.isOnline == false)

        await app.signOut(connectionID: "C1")     // bumps the generation → the parked probe is now stale

        // Release the gate: the probe resumes and `authorize()` returns 200, but the generation
        // guard turns it into a no-op — the connection stays signed out.
        await transport.enqueue(status: 200, json: "{}")
        await transport.openGate()
        // Drain the cooperative executor so the resumed probe runs to its (stale) guard and returns.
        // On the stale path it writes nothing, so there is no positive signal to await; a regression
        // (missing guard) would instead flip `isOnline` / build a socket synchronously right after
        // `authorize()` returns — well within this bound — which the asserts below would catch.
        for _ in 0..<200 { await Task.yield() }

        #expect(app.needsSignIn.contains("C1"))                                // stays signed-out
        #expect(app.isOnline == false)                                         // NOT resurrected
        #expect(sockets.count == 0)                                            // no socket constructed after signOut
        #expect(await transport.requestCount(pathContains: "/libraries") == 0) // probe never reached libraries
    }

    /// Race B — a slow/abandoned `connect()` must not clobber a newer activation. Begin a connect
    /// whose login is parked on a `GatedTransport`; while it hangs, `activateConnection(NEWER)`
    /// supersedes it (bumping the generation) and its probe brings `NEWER` online with a live
    /// socket. Release the stale connect's gate so its login SUCCEEDS — the generation guard must
    /// make it discard itself: `activeConnectionID` stays `NEWER` (no silent reassignment) and
    /// `NEWER`'s socket is never torn down (no `startSocket`/`stopSocket` from the stale connect).
    @Test func staleConnectDoesNotClobberNewerActivation() async throws {
        final class SocketConstructionCounter { private(set) var count = 0; func record() { count += 1 } }

        let dir = makeTempDir()
        let transport = GatedTransport(gatePath: "/login")   // park the connect mid-login
        // FIFO responses, consumed in the deterministic order the barriers below enforce:
        await transport.enqueue(status: 200, json: statusOK)      // connect: /status
        await transport.enqueue(status: 200, json: "{}")          // NEWER probe: /api/authorize
        await transport.enqueue(status: 200, json: librariesOK)   // NEWER probe: /libraries
        await transport.enqueue(status: 200, json: loginOK)       // connect: /login (served on gate open)
        let tokenStore = InMemoryTokenStore()
        let sockets = SocketConstructionCounter()
        let app = AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in sockets.record(); return FakeSocket() },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport }
        )
        // The newer connection, seeded with tokens so its probe comes online with a socket.
        try app.cache.upsertConnection(CachedConnection(id: "NEWER", address: "http://newer:13378", name: "Newer",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "NEWER")

        // Begin a connect that clears /status then parks mid-login.
        let stale = Task { await app.connect(serverURL: "http://stale:13378", username: "root", password: "pw") }
        while await transport.requestCount(pathContains: "/login") == 0 { await Task.yield() }
        #expect(app.phase == .connecting)

        // While the connect hangs, activate a different connection — supersedes the connect.
        await app.activateConnection("NEWER")
        #expect(app.activeConnectionID == "NEWER")
        while !app.isOnline { await Task.yield() }   // probe consumed /api/authorize + /libraries, socket up
        #expect(sockets.count == 1)

        // Release the stale connect's gate: its login succeeds (200) but the generation guard
        // discards it — no reassignment of activeConnectionID, no teardown of NEWER's socket.
        await transport.openGate()
        await stale.value

        #expect(app.activeConnectionID == "NEWER")   // stale connect discarded, NOT clobbered
        #expect(app.isOnline == true)                 // NEWER still online
        #expect(sockets.count == 1)                   // NEWER's socket never torn down or rebuilt
    }

    /// The generation bump must never strand `phase == .connecting`. A signOut fired while a
    /// `connect()` is parked mid-login makes every one of that connect's subsequent guards bail —
    /// including the catch blocks that normally reset `phase` — so without `signOut`'s
    /// `.connecting → .disconnected` normalization, `phase` would stay `.connecting` forever and
    /// both connect entry guards would refuse every future sign-in (a dead sign-in surface until
    /// relaunch). Asserts the phase is normalized immediately, stays normalized after the stale
    /// connect completes (its login SUCCEEDS and is discarded), and — the load-bearing recovery
    /// check — a subsequent fresh `connect()` is not refused and runs all the way to `.connected`.
    @Test func signOutDuringConnectDoesNotStrandPhase() async throws {
        let dir = makeTempDir()
        let transport = GatedTransport(gatePath: "/login")   // park the connect mid-login
        // FIFO, consumed in the deterministic order the barriers below enforce:
        await transport.enqueue(status: 200, json: statusOK)      // stale connect: /status
        await transport.enqueue(status: 200, json: loginOK)       // stale connect: /login (on gate open)
        await transport.enqueue(status: 200, json: statusOK)      // recovery connect: /status
        await transport.enqueue(status: 200, json: loginOK)       // recovery connect: /login (gate now open)
        await transport.enqueue(status: 200, json: librariesOK)   // recovery connect: /libraries
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        // An unrelated stored row to sign out of while the connect is in flight.
        try app.cache.upsertConnection(CachedConnection(id: "R1", address: "http://other:13378", name: "Other",
                                                        username: "root", authMethod: "local", sortIndex: 0))

        let stale = Task { await app.connect(serverURL: "http://s:13378", username: "root", password: "pw") }
        while await transport.requestCount(pathContains: "/login") == 0 { await Task.yield() }
        #expect(app.phase == .connecting)

        await app.signOut(connectionID: "R1")
        #expect(app.phase == .disconnected)          // normalized by signOut, not left .connecting

        // Release the gate: the stale connect's login lands 200, but its generation is stale — it
        // must discard itself without re-entering .connecting or publishing any state.
        await transport.openGate()
        await stale.value
        #expect(app.phase == .disconnected)          // still not stranded
        #expect(app.activeConnectionID == nil)       // no stale publication while disconnected
        #expect(app.errorMessage == nil)             // discarded silently, no bogus alert

        // THE recovery assertion: the sign-in surface is alive — a fresh connect is accepted by
        // the `phase != .connecting` entry guard and completes normally.
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)
        #expect(app.errorMessage == nil)
    }

    // MARK: - OIDC

    /// A canned OIDC browser closure: ignores the authorize URL and returns a fixed
    /// `colophon://oauth?code&state` callback — the "fake browser" the plan requires in place of
    /// a real `ASWebAuthenticationSession` in unit tests.
    private func fakeBrowser(state: String = "STATE1", code: String = "CODE1") -> @Sendable (URL) async throws -> URL {
        { _ in URL(string: "colophon://oauth?code=\(code)&state=\(state)")! }
    }

    /// Full `connectWithOIDC` happy path: `/status` (advertising openid) → OIDCFlow's step-1
    /// redirect + step-3 exchange (through the SAME `MockTransport` the app's `/status`/`/libraries`
    /// calls use) → `completeOIDC` → the shared tail. Asserts a `CachedConnection` was found-or-created
    /// with `authMethod == "openid"` and the IdP-issued username, `phase == .connected`, the tail's
    /// `/libraries` request actually fired, and the socket started (its `reauthenticateCount` picks
    /// up the token `completeOIDC` already yielded, since `tokenUpdates` buffers the newest value).
    @Test func connectWithOIDCFindsOrCreatesAndRunsTail() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: #"{"isInit":true,"serverVersion":"2.35.1","authMethods":["local","openid"]}"#)
        // OIDCFlow step 1: /auth/openid → 302 carrying the IdP authorize URL + server state.
        await transport.enqueue(status: 302, json: "",
            headers: ["Location": "https://idp.example/auth?state=STATE1"])
        // OIDCFlow step 3: /auth/openid/callback → 200 LoginResponse.
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"oidcuser","accessToken":"acc-oidc","refreshToken":"ref-oidc"}}"#)
        await transport.enqueue(status: 200, json: librariesOK)
        let fakeSocket = FakeSocket()
        let app = AppState(
            transportProvider: { transport },
            cacheDirectory: makeTempDir(),
            socketFactory: { _, _ in fakeSocket },
            tokenStore: InMemoryTokenStore(),
            oidcTransportProvider: { transport }
        )

        await app.connectWithOIDC(serverURL: "http://s:13378", browser: fakeBrowser())

        #expect(app.phase == .connected)
        let connections = try app.cache.connections()
        #expect(connections.count == 1)
        #expect(connections.first?.authMethod == "openid")
        #expect(connections.first?.username == "oidcuser")
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.contains("/libraries") })
        while fakeSocket.reauthenticateCount == 0 { await Task.yield() }
        #expect(fakeSocket.reauthenticateCount == 1)
    }

    /// A user-cancelled ASWebAuthenticationSession (the browser closure throwing
    /// `.canceledLogin`) is a silent no-op: `.disconnected` with guards reset and NO error
    /// alert. The thrown error is deliberately a RAW `NSError` (domain + code 1) — the exact
    /// form the ObjC ASWebAuthenticationSession machinery produces at runtime — proving the
    /// production `error as? ASWebAuthenticationSessionError` match bridges from it (verified:
    /// it does; `_BridgedStoredNSError` casts succeed on a matching-domain NSError).
    @Test func oidcUserCancelIsSilent() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: #"{"isInit":true,"serverVersion":"2.35.1","authMethods":["openid"]}"#)
        // OIDCFlow step 1 — consumed before the browser closure is invoked.
        await transport.enqueue(status: 302, json: "",
            headers: ["Location": "https://idp.example/auth?state=STATE1"])
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connectWithOIDC(serverURL: "http://s:13378") { _ in
            throw NSError(domain: ASWebAuthenticationSessionErrorDomain,
                          code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
        }

        #expect(app.phase == .disconnected)
        #expect(app.errorMessage == nil)          // silent — no alert for a user cancel
        #expect(app.activeConnectionID == nil)
        // The flow really reached the browser hop (status + step-1 both consumed) — the cancel
        // was thrown from inside the session, not short-circuited earlier. Any non-cancel
        // failure here would have set `errorMessage`, so the nil above is discriminating.
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.contains("/auth/openid") })
    }

    /// The version gate binds on the OIDC path exactly like the password path: an old server is
    /// rejected at `/status`, before the browser closure is ever invoked (no `/auth/openid` hit).
    @Test func oldServerIsGatedOnOIDCPath() async throws {
        let transport = MockTransport()
        await transport.enqueue(status: 200, json: #"{"isInit":true,"serverVersion":"2.20.0","authMethods":["openid"]}"#)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connectWithOIDC(serverURL: "http://s:13378", browser: fakeBrowser())

        #expect(app.phase == .disconnected)
        #expect(app.errorMessage?.contains("2.26.0") == true)
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.contains("/status") })
        #expect(!paths.contains { $0.contains("/auth/openid") })
    }

    /// A second `connectWithOIDC()` fired while the first is still `.connecting` bails at the same
    /// reentrancy guard `connect()` uses — the first `/status` stays the only one recorded.
    @Test func connectWithOIDCReentrancyGuard() async throws {
        let transport = GatedTransport(gatePath: "/status")
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        let first = Task { await app.connectWithOIDC(serverURL: "http://s:13378", browser: fakeBrowser()) }
        while await transport.requestCount(pathContains: "/status") == 0 { await Task.yield() }

        await app.connectWithOIDC(serverURL: "http://s:13378", browser: fakeBrowser())
        #expect(await transport.requestCount(pathContains: "/status") == 1)

        await transport.openGate()
        await first.value
        #expect(await transport.requestCount(pathContains: "/status") == 1)
    }

    /// The complementary guard case: a genuinely empty library (`total == 0`, `results == []`)
    /// IS a completed page-through, so `replaceItems([])` runs and wipes the stale cached rows —
    /// the server really has nothing, and keeping ghosts would be the reconciliation bug.
    @Test func emptyLibraryTotalZeroWipes() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "ghost", connectionID: cid, libraryID: "lib1", title: "Ghost",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 0, results: []))

        try await app.refreshItems(libraryID: "lib1")

        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").isEmpty)
    }

}

// MARK: - Settings plumbing (Task 9 / Fix round 2)

/// Both tests here mutate the process-global `UserDefaults.standard` keys
/// `colophon.defaultRate`/`colophon.skipInterval` across `await` suspension points. Swift Testing
/// runs `@Test`s within a suite concurrently by default, so two tests racing on the same global
/// keys can interleave and flake (one test's `set` landing between another's `set` and its
/// `startPlayback` read). `.serialized` forces this suite's tests to run one at a time, restoring
/// the ordering the shared-mutable-global assumes. Kept as its own suite (rather than marking all
/// of `AppStateTests` serialized) so the rest of the file keeps running concurrently.
@MainActor
@Suite(.serialized)
struct SettingsPlumbingTests {
    private let statusOK = #"{"isInit":true,"serverVersion":"2.35.1","authMethods":["local"]}"#
    private let loginOK = #"{"user":{"id":"u1","username":"root","accessToken":"acc1","refreshToken":"ref1"}}"#
    private let librariesOK = #"{"libraries":[{"id":"lib1","name":"Books","mediaType":"book","icon":null,"displayOrder":0}]}"#

    /// The `PlaybackSession` shape `startPlayback` decodes — one track, no chapters. (Mirrors the
    /// fixture in `AppStateTests`.)
    private let playSessionJSON = #"""
    {"id":"sess1","libraryItemId":"i1","episodeId":null,"displayTitle":"Book","displayAuthor":"Auth","duration":100,"startTime":0,"currentTime":0,"playMethod":0,"audioTracks":[{"index":1,"startOffset":0,"duration":100,"title":null,"contentUrl":"/x","mimeType":"audio/mpeg"}],"chapters":[]}
    """#

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    private func enqueueSuccessfulConnect(_ transport: MockTransport) async {
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 200, json: loginOK)
        await transport.enqueue(status: 200, json: librariesOK)
    }

    private func makeApp(dir: URL, transport: Transport, tokenStore: any TokenStore) -> AppState {
        AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in FakeSocket() },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport })
    }

    /// Saves the current value (if any) of a `UserDefaults.standard` key and returns a restore
    /// closure — used so these tests can set `colophon.defaultRate`/`colophon.skipInterval`
    /// (real `AppStorage`-compatible keys, not test-injected) without leaking state into other
    /// tests that share the same process-wide `UserDefaults.standard`.
    private func snapshotDefault(_ key: String) -> () -> Void {
        let previous = UserDefaults.standard.object(forKey: key)
        return {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// `AppState.startPlayback` reads the Settings-stored default rate and skip interval — the
    /// same `UserDefaults.standard` keys `SettingsView`'s `@AppStorage` Pickers write into — and
    /// lands them on `playback` before a freshly opened book starts playing.
    @Test func defaultRateAndSkipIntervalLandOnPlaybackLoad() async throws {
        let restoreRate = snapshotDefault(AppState.defaultRateKey)
        let restoreSkip = snapshotDefault(AppState.skipIntervalKey)
        defer { restoreRate(); restoreSkip() }
        UserDefaults.standard.set(1.75, forKey: AppState.defaultRateKey)
        UserDefaults.standard.set(30, forKey: AppState.skipIntervalKey)

        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        await app.startPlayback(itemID: "i1")

        #expect(app.playback.rate == 1.75)
        #expect(app.playback.skipInterval == 30)
    }

    /// Unset Settings keys (fresh install, `SettingsView` never opened) read as the documented
    /// defaults — 1.0× and 15s — not `UserDefaults`' bare-key zero value.
    @Test func unsetSettingsKeysReadAsDocumentedDefaults() async throws {
        let restoreRate = snapshotDefault(AppState.defaultRateKey)
        let restoreSkip = snapshotDefault(AppState.skipIntervalKey)
        defer { restoreRate(); restoreSkip() }
        UserDefaults.standard.removeObject(forKey: AppState.defaultRateKey)
        UserDefaults.standard.removeObject(forKey: AppState.skipIntervalKey)

        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        await app.startPlayback(itemID: "i1")

        #expect(app.playback.rate == 1.0)
        #expect(app.playback.skipInterval == 15)
    }
}
