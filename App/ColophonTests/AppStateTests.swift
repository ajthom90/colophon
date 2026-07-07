import Testing
import Foundation
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
