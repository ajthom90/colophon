import Testing
import Foundation
import AuthenticationServices
import ABSKit
import ABSKitTestSupport
import ABSRealtime
import LibraryCache
import PlayerEngine
import ColophonShared
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
            oidcTransportProvider: transportProvider,
            // A fake download manager so activating a connection (which reconciles downloads on
            // launch) never stands up a real background `URLSession` in the test host.
            downloadManagerProvider: { FakeDownloadManaging() }
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

    /// The progress-join (Task 7): `refreshProgress()` calls `GET /api/me` and upserts each
    /// `mediaProgress` entry into `CachedProgress` (the source of the home shelves' pills, since
    /// shelf entities carry no progress). Asserts the entry lands under the active connection's ID,
    /// with `episodeId: null → ""` per the 3-part PK, and that the server's `lastUpdate` is used.
    @Test func mediaProgressFromMeLandsInCache() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        await transport.enqueue(status: 200, json: #"""
        {"id":"root","username":"root","mediaProgress":[
          {"libraryItemId":"li_art","episodeId":null,"progress":0.0277,"currentTime":120.5,"duration":4337.26,"isFinished":false,"lastUpdate":1783453076895}
        ]}
        """#)

        await app.refreshProgress()

        let joined = try #require(try app.cache.progress(connectionID: cid, itemID: "li_art"))
        #expect(joined.currentTime == 120.5)
        #expect(joined.isFinished == false)
        #expect(joined.episodeID == "")             // null episodeId → "" per the 3-part PK
        #expect(joined.lastUpdate == 1783453076895) // server timestamp, not wall-clock
        let mePaths = await transport.recorded.compactMap { $0.url?.path }
        #expect(mePaths.contains("/api/me"))
    }

    /// Extends `mediaProgressFromMeLandsInCache` (M1c-c Task 3): a `me()` response mixing a
    /// book-style entry (`episodeId: null`) and a real episode entry (`episodeId` populated) for
    /// the SAME item lands as two DISTINCT `cachedProgress` rows — the 3-part PK, not a collision —
    /// confirming `refreshProgress`'s existing `entry.episodeId` mapping (M1a Task 7) already
    /// handles per-episode progress with no change needed.
    @Test func mediaProgressFromMeDistinguishesEpisodeFromBookProgress() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        await transport.enqueue(status: 200, json: #"""
        {"id":"root","username":"root","mediaProgress":[
          {"libraryItemId":"pod1","episodeId":null,"progress":0.1,"currentTime":50,"duration":500,"isFinished":false,"lastUpdate":1000},
          {"libraryItemId":"pod1","episodeId":"ep1","progress":0.9,"currentTime":450,"duration":500,"isFinished":true,"lastUpdate":2000}
        ]}
        """#)

        await app.refreshProgress()

        let bookProgress = try #require(try app.cache.progress(connectionID: cid, itemID: "pod1"))
        let episodeProgress = try #require(try app.cache.progress(connectionID: cid, itemID: "pod1", episodeID: "ep1"))
        #expect(bookProgress.episodeID == "")
        #expect(bookProgress.currentTime == 50)
        #expect(bookProgress.isFinished == false)
        #expect(episodeProgress.episodeID == "ep1")
        #expect(episodeProgress.currentTime == 450)
        #expect(episodeProgress.isFinished == true)
    }

    /// M1c-c Task 3: `refreshPodcastEpisodes(itemID:)` fetches the podcast item (`podcastItem(id:)`)
    /// and reconciles `media.episodes[]` into the v2 `cachedEpisode` table via `upsertEpisodes` —
    /// the AppState-level hook the podcast-detail view (Task 4) will call on appear. Asserts the
    /// mapping preserves `season`/`episode` as STRINGS (not coerced) and carries every other
    /// `PodcastEpisode` field through to its `CachedEpisode` column.
    @Test func refreshPodcastEpisodesFetchesAndUpsertsEpisodes() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        await transport.enqueue(status: 200, json: #"""
        {"id":"pod1","libraryId":"lib1","updatedAt":1700000000000,"media":{
          "metadata":{"title":"Colophon Test Podcast","author":"Colophon Dev","description":"<p>desc</p>",
                      "releaseDate":null,"genres":[],"feedUrl":"http://x/feed.xml","imageUrl":"http://x/cover.jpg",
                      "explicit":true,"language":"en-us","type":"episodic"},
          "coverPath":"/podcasts/x/cover.jpg",
          "episodes":[
            {"libraryItemId":"pod1","podcastId":"m1","id":"ep1","index":null,"season":"1","episode":"1",
             "episodeType":"full","title":"Episode One","subtitle":"Sub1","description":"<p>d1</p>",
             "enclosure":{"url":"http://x/e1.mp3","type":"audio/mpeg","length":"3723859"},
             "guid":"guid-1","pubDate":"Mon, 06 Jan 2025 08:00:00 GMT","chapters":[],
             "publishedAt":1736150400000,"size":3724390,"duration":465.397551},
            {"libraryItemId":"pod1","podcastId":"m1","id":"ep2","index":null,"season":"1","episode":"2",
             "episodeType":"full","title":"Episode Two","subtitle":"Sub2","description":"<p>d2</p>",
             "enclosure":{"url":"http://x/e2.mp3","type":"audio/mpeg","length":"4055167"},
             "guid":"guid-2","pubDate":"Mon, 13 Jan 2025 08:00:00 GMT","chapters":[],
             "publishedAt":1736755200000,"size":4055751,"duration":506.827755}
          ]}}
        """#)

        try await app.refreshPodcastEpisodes(itemID: "pod1")

        let episodes = try app.cache.episodes(connectionID: cid, itemID: "pod1")
        #expect(episodes.map(\.episodeID) == ["ep2", "ep1"])   // newest publishedAt first
        let ep1 = try #require(episodes.first { $0.episodeID == "ep1" })
        #expect(ep1.season == "1")
        #expect(ep1.episode == "1")
        #expect(ep1.title == "Episode One")
        #expect(ep1.episodeType == "full")
        #expect(ep1.episodeDescription == "<p>d1</p>")
        #expect(ep1.pubDate == "Mon, 06 Jan 2025 08:00:00 GMT")
        #expect(ep1.publishedAt == 1736150400000)
        #expect(ep1.durationSeconds == 465.397551)
        #expect(ep1.sizeBytes == 3724390)
        #expect(ep1.guid == "guid-1")

        let podcastPaths = await transport.recorded.compactMap { $0.url?.path }
        #expect(podcastPaths.contains { $0.contains("/items/pod1") })
    }

    // A minimal episode `/play/:episodeId` envelope (same shape as a book /play). `displayAuthor`
    // is the podcast's AUTHOR field ("Colophon Dev"), distinct from the podcast TITLE the caller
    // supplies as the now-playing author — so the override is observable.
    private let episodePlayJSON = #"""
    {"id":"epsess1","libraryItemId":"pod1","episodeId":"ep1",
     "displayTitle":"Episode One: Laying Plans","displayAuthor":"Colophon Dev",
     "duration":465.4,"startTime":0,"currentTime":0,"playMethod":0,"chapters":[],
     "audioTracks":[{"index":1,"startOffset":0,"duration":465.4,"title":"e1.mp3",
                     "contentUrl":"/api/items/pod1/file/1","mimeType":"audio/mpeg"}]}
    """#

    private let bookPlayJSON = #"""
    {"id":"bksess1","libraryItemId":"book1","episodeId":null,
     "displayTitle":"A Book","displayAuthor":"An Author",
     "duration":100,"startTime":0,"currentTime":0,"playMethod":0,"chapters":[],
     "audioTracks":[{"index":1,"startOffset":0,"duration":100,"title":"t.mp3",
                     "contentUrl":"/api/items/book1/file/1","mimeType":"audio/mpeg"}]}
    """#

    /// M1c-c Task 5: `startPlayback(itemID:episodeId:)` opens the EPISODE session — it POSTs to the
    /// episode-scoped `/api/items/:id/play/:episodeId` (via `client.playEpisode`), NOT the book
    /// `/api/items/:id/play` — sets `nowPlayingEpisodeID`, and surfaces the episode title with the
    /// PODCAST TITLE as the now-playing author (the show-name-as-secondary override). Reuses the
    /// exact book session/guard wiring (no forked path).
    @Test func episodePlaybackOpensEpisodeSessionAndTracksEpisode() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)
        await transport.enqueue(status: 200, json: episodePlayJSON)

        await app.startPlayback(itemID: "pod1", episodeId: "ep1", podcastTitle: "Colophon Test Podcast")

        let paths = await transport.recorded.compactMap { $0.url?.path }
        // The episode-scoped path was hit — and the book /play was NOT.
        #expect(paths.contains { $0.hasSuffix("/items/pod1/play/ep1") })
        #expect(!paths.contains { $0.hasSuffix("/items/pod1/play") })
        #expect(app.nowPlayingItemID == "pod1")
        #expect(app.nowPlayingEpisodeID == "ep1")
        // Episode title primary; podcast TITLE (not the session's "Colophon Dev" author) secondary.
        #expect(app.playback.title == "Episode One: Laying Plans")
        #expect(app.playback.author == "Colophon Test Podcast")
    }

    /// The book path is unchanged by the episode extension: no `episodeId` → book `startPlayback`
    /// (`/api/items/:id/play`), `nowPlayingEpisodeID` stays nil, and the author is the session's own
    /// `displayAuthor` (no override).
    @Test func bookPlaybackLeavesEpisodeIDNilAndUsesSessionAuthor() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        await transport.enqueue(status: 200, json: bookPlayJSON)

        await app.startPlayback(itemID: "book1")

        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.hasSuffix("/items/book1/play") })
        #expect(app.nowPlayingItemID == "book1")
        #expect(app.nowPlayingEpisodeID == nil)
        #expect(app.playback.author == "An Author")
    }

    // MARK: - App-Group snapshot publishing (M2b Task 1)

    /// The now-playing snapshot-publish wiring end to end, hermetically (a temp-dir `SharedStore`
    /// seam — no provisioned App Group needed). Starting playback publishes a `NowPlayingSnapshot`
    /// the widget can read (right item + title); retiring the session publishes ONE authoritative
    /// CLEAR so no stale now-playing lingers after playback ends.
    /// RED-meaningful two ways: dropping the `onNowPlayingStateChange`→`publishNowPlayingSnapshot`
    /// wiring leaves `readNowPlaying()` nil after start; dropping `retireCurrentSession`'s final
    /// clear leaves the started snapshot lingering (non-nil) after retire.
    @Test func startPublishesNowPlayingSnapshotAndRetireClearsIt() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let container = makeTempDir()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let store = SharedStore(suiteName: "colophon.tests.\(UUID().uuidString)", containerURL: container)
        let app = AppState(
            transportProvider: { transport },
            cacheDirectory: makeTempDir(),
            socketFactory: { _, _ in FakeSocket() },
            tokenStore: InMemoryTokenStore(),
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() },
            snapshotStore: store)

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        await transport.enqueue(status: 200, json: bookPlayJSON)

        await app.startPlayback(itemID: "book1")

        // A now-playing snapshot was published into the (temp) App-Group store — right item + title.
        let published = try #require(store.readNowPlaying())
        #expect(published.itemID == "book1")
        #expect(published.title == "A Book")
        #expect(published.episodeID == nil)

        // Retiring the session publishes the authoritative CLEAR — no stale now-playing lingers.
        await app.closeCurrentSession()
        #expect(app.nowPlayingItemID == nil)
        #expect(store.readNowPlaying() == nil)
    }

    /// A queued EPISODE (its `QueueEntry.episodeId` set) advances through the episode path:
    /// `advanceToNext` opens `/play/:episodeId`, sets `nowPlayingEpisodeID`, and passes the entry's
    /// `author` (the podcast title) through as the now-playing author — then commits (drops) the entry.
    @Test func advanceToQueuedEpisodePlaysViaEpisodePath() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        app.addToQueue(itemID: "pod1", title: "Episode One: Laying Plans",
                       author: "Colophon Test Podcast", episodeId: "ep1")
        #expect(app.queue.isEmpty == false)
        await transport.enqueue(status: 200, json: episodePlayJSON)

        await app.advanceToNext()

        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.hasSuffix("/items/pod1/play/ep1") })
        #expect(app.nowPlayingEpisodeID == "ep1")
        #expect(app.playback.author == "Colophon Test Podcast")
        #expect(app.queue.isEmpty)   // committed after a successful start
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

    // MARK: - Task 8: filtered vs unfiltered refresh (the browse deviation the grid rests on)

    /// A FILTERED refresh must NOT reconcile-delete: the server returns only the matching items,
    /// but the non-matching rows already in the cache MUST survive (a transient filter can't
    /// destroy the offline browse set). It upserts the matches and captures ONLY the matching IDs
    /// as the grid's order.
    @Test func filteredRefreshPreservesNonMatchingCachedRows() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        // Three cached items; the filter will match only "a".
        for id in ["a", "b", "c"] {
            try app.cache.upsertItemsPage(
                [CachedItem(id: id, connectionID: cid, libraryID: "lib1", title: "Title \(id)",
                            authorName: nil, duration: 1, updatedAt: 1)],
                connectionID: cid, libraryID: "lib1")
        }
        app.libraryFilter = LibraryFilter(group: "authors", displayValue: "Sun Tzu", rawValue: "aut_x")
        // The filtered page returns only "a" (total 1) — the server's matching set.
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 1, results: ["a"]))

        try await app.refreshItems(libraryID: "lib1")

        // All three rows STILL EXIST (upsert, not replaceItems) — "b"/"c" were not deleted.
        #expect(Set(try app.cache.items(connectionID: cid, libraryID: "lib1").map(\.id)) == ["a", "b", "c"])
        // The grid's captured order is exactly the single match.
        #expect(app.libraryItemOrder["lib1"] == ["a"])
    }

    /// A FILTERED refresh that matches ZERO items captures a PRESENT-but-EMPTY order (not nil), so
    /// the grid renders "No matches" rather than falling back to the whole cached library — the
    /// Important bug the round-2 review caught. Cached rows are still preserved.
    @Test func filteredRefreshZeroMatchesCapturesEmptyOrderNotNil() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        for id in ["a", "b"] {
            try app.cache.upsertItemsPage(
                [CachedItem(id: id, connectionID: cid, libraryID: "lib1", title: "Title \(id)",
                            authorName: nil, duration: 1, updatedAt: 1)],
                connectionID: cid, libraryID: "lib1")
        }
        app.libraryFilter = LibraryFilter(group: "genres", displayValue: "Nope", rawValue: "Nope")
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 0, results: []))

        try await app.refreshItems(libraryID: "lib1")

        // Order captured as an EMPTY array (key present) — the grid shows "No matches".
        #expect(app.libraryItemOrder["lib1"] != nil)
        #expect(app.libraryItemOrder["lib1"]?.isEmpty == true)
        // Cached rows preserved (the filter didn't nuke the cache).
        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").count == 2)
    }

    /// The UNFILTERED sibling: with no filter, a completed page missing a previously-cached row
    /// still DELETES it (Task 3 reconciliation intact), and captures the full server order.
    @Test func unfilteredRefreshStillReconciles() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        for id in ["keep", "gone"] {
            try app.cache.upsertItemsPage(
                [CachedItem(id: id, connectionID: cid, libraryID: "lib1", title: "Title \(id)",
                            authorName: nil, duration: 1, updatedAt: 1)],
                connectionID: cid, libraryID: "lib1")
        }
        #expect(app.libraryFilter == nil)   // no filter → reconcile path
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 1, results: ["keep"]))

        try await app.refreshItems(libraryID: "lib1")

        // "gone" is reconciled away; only "keep" survives, and it's the captured order.
        #expect(try app.cache.items(connectionID: cid, libraryID: "lib1").map(\.id) == ["keep"])
        #expect(app.libraryItemOrder["lib1"] == ["keep"])
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
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() })
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

    // MARK: - Offline-aware browse guards (M2a Task 7, fix round 2)

    /// Drives an `AppState` into the "cached-offline, server KNOWN-unreachable" state — a token'd
    /// cached-first activation whose `/authorize` probe FAILS (a `MockTransport` with nothing queued
    /// throws like a dead host) — and waits for the detached probe to SETTLE so `isOffline` is
    /// authoritative. `client` is NON-nil here (built before the probe), so a guard test isolates the
    /// `isOffline` decision rather than the trivial nil-client short-circuit. Seeds one cached item so
    /// the browse fallback (a `refreshBanner` over still-usable rows) can engage. This is exactly the
    /// state a real self-hosted "server stopped, device online" launch reaches once its probe fails.
    private func makeOfflineActivatedApp() async throws -> (AppState, MockTransport) {
        let transport = MockTransport()                    // nothing queued → the probe fails like a dead host
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: tokenStore)
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try app.cache.upsertLibraries([CachedLibrary(id: "L1", connectionID: "C1", name: "Books",
                                                     mediaType: "book", displayOrder: 0)], connectionID: "C1")
        try app.cache.upsertItemsPage([CachedItem(id: "i1", connectionID: "C1", libraryID: "L1",
                                                  title: "Cached Book", authorName: nil, duration: 1, updatedAt: 1)],
                                      connectionID: "C1", libraryID: "L1")
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")

        await app.activateConnection("C1")
        // Wait for the detached probe to SETTLE (fail) so `isProbingConnection` clears and `isOffline`
        // is authoritative.
        var spins = 0
        while !app.isOffline, spins < 5000 { await Task.yield(); spins += 1 }
        return (app, transport)
    }

    /// OFFLINE (server known-unreachable): `refreshItems` SHORT-CIRCUITS to the cache — it issues NO
    /// `/items` request (which would hang against a dead host) and instead engages the non-blocking
    /// `refreshBanner` over the still-usable cached rows. RED-verify: reverting the guard to the raw
    /// link (`isNetworkAvailable`, which stays `true` when only the SERVER is down) makes a doomed
    /// `/items` request get recorded → `itemsAfter == itemsBefore` fails.
    @Test func refreshItemsShortCircuitsToCacheWhenServerKnownUnreachable() async throws {
        let (app, transport) = try await makeOfflineActivatedApp()
        #expect(app.isOffline)                                  // precondition: probe settled offline…
        #expect(app.client != nil)                              // …with a live client (isolates the isOffline guard)
        let itemsBefore = await transport.recorded.filter { ($0.url?.path ?? "").contains("/items") }.count

        try await app.refreshItems(libraryID: "L1")

        let itemsAfter = await transport.recorded.filter { ($0.url?.path ?? "").contains("/items") }.count
        #expect(itemsAfter == itemsBefore)                      // NO doomed /items request attempted
        #expect(app.refreshBanner?.libraryID == "L1")           // offline fallback engaged (cache stays usable)
        #expect(app.errorMessage == nil)                        // never a blocking alert
    }

    /// ONLINE (no regression): the SAME `refreshItems` DOES issue a real `/items` request when the
    /// server is reachable — the guard is a genuine no-op online. Complements the offline test above.
    @Test func refreshItemsStillFetchesFromServerWhenOnline() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 1, results: ["i1"]))
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        #expect(app.isOffline == false)                         // a fresh login is online — the guard must NOT fire

        try await app.refreshItems(libraryID: "lib1")

        let itemsCount = await transport.recorded.filter { ($0.url?.path ?? "").contains("/items") }.count
        #expect(itemsCount >= 1)                                // real fetch happened; online path unregressed
    }

    /// OFFLINE: `SearchModel`'s server tier is skipped — it makes NO `/search` request (the instant
    /// local FTS tier is the whole result). Uses the token'd-offline app so `client` is non-nil,
    /// isolating the `isOffline` guard from the nil-client short-circuit. RED-verify: reverting to
    /// `isNetworkAvailable` records a doomed `/search` request → `searchCount == 0` fails.
    @Test func searchModelServerTierSkippedWhenServerKnownUnreachable() async throws {
        let (app, transport) = try await makeOfflineActivatedApp()
        #expect(app.isOffline)
        let model = SearchModel(app: app, connectionID: "C1", libraryID: "L1",
                                libraryMediaType: "book", debounce: .milliseconds(1))
        model.updateQuery("war")
        await model.pendingSearch?.value

        let searchCount = await transport.recorded.filter { ($0.url?.path ?? "").contains("/search") }.count
        #expect(searchCount == 0)                               // NO doomed server search attempted
    }

    /// ONLINE (no regression): the SAME `SearchModel` DOES hit `/search` when the server is reachable.
    @Test func searchModelServerTierRunsWhenOnline() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: "{}")        // the /search response
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        #expect(app.isOffline == false)
        let model = SearchModel(app: app, connectionID: cid, libraryID: "lib1",
                                libraryMediaType: "book", debounce: .milliseconds(1))
        model.updateQuery("war")
        await model.pendingSearch?.value

        let searchCount = await transport.recorded.filter { ($0.url?.path ?? "").contains("/search") }.count
        #expect(searchCount >= 1)                               // real server search happened; online unregressed
    }

    /// The `isOffline` signal must NOT false-positive during the INITIAL in-flight probe — the flaw a
    /// bare `phase == .connected && !isOnline` would have (the cached-first activation publishes
    /// `.connected` BEFORE the probe, so `phase` alone doesn't exclude it). With the probe parked on a
    /// gate: `phase == .connected`, `isOnline == false`, yet `isOffline` is FALSE (still probing). Only
    /// once the probe SETTLES as a failure does `isOffline` become true. RED-verify: dropping
    /// `&& !isProbingConnection` from `isOffline` makes the mid-probe `isOffline == false` assertion fail.
    @Test func isOfflineDoesNotFalsePositiveDuringInitialProbe() async throws {
        let transport = GatedTransport(gatePath: "/api/authorize")   // park the probe mid-authorize
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: tokenStore)
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")

        await app.activateConnection("C1")                       // returns; probe launched, parks on the gate
        while await transport.requestCount(pathContains: "/api/authorize") == 0 { await Task.yield() }

        // MID-PROBE: connected + not-yet-online, but NOT "offline" — the browse guards must not fire.
        #expect(app.phase == .connected)
        #expect(app.isOnline == false)
        #expect(app.isOffline == false)                          // ← the false-positive guard

        await transport.openGate()                               // no response queued → authorize throws → probe fails
        var spins = 0
        while !app.isOffline, spins < 5000 { await Task.yield(); spins += 1 }
        #expect(app.isOffline == true)                           // settled offline → fallback now engages
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

    // MARK: - Up-next queue advance (Task 8)

    /// `advanceToNext` with a non-empty queue pops the FRONT entry, closes the finished session, and
    /// starts the next book: the queue drops the played entry (deterministic), and a `/play` for the
    /// next item id is issued. (Multi-book A→B advance can't be shown live — the seed has one book —
    /// so this is the unit proof of the deliverable.)
    @Test func advanceToNextPlaysFrontOfQueueThenRemovesIt() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play i1
        await transport.enqueue(status: 200, json: "{}")              // absorbs me(i1)/flush
        await transport.enqueue(status: 200, json: "{}")              // /close i1 on retire
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play i2 (advance target)
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)
        await app.startPlayback(itemID: "i1")
        #expect(app.playback.isPlaying == true)

        app.addToQueue(itemID: "i2", title: "Second", author: "Auth")
        app.addToQueue(itemID: "i3", title: "Third", author: "Auth")
        #expect(app.queue.entries.map(\.itemID) == ["i2", "i3"])

        await app.advanceToNext()

        // The front (i2) was popped; i3 remains — the core decision, fully deterministic.
        #expect(app.queue.entries.map(\.itemID) == ["i3"])
        // And a /play for i2 was issued (advance handed the front to startPlayback).
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.contains("/items/i2/play") })
        #expect(app.nowPlayingItemID == "i2")
    }

    /// `advanceToNext` with an EMPTY queue just retires the current session and stops — nothing new
    /// plays (no second `/play`), playback halts, and the now-playing item clears.
    @Test func advanceToNextWithEmptyQueueStops() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play i1
        await transport.enqueue(status: 200, json: "{}")              // absorbs me(i1)/flush
        await transport.enqueue(status: 200, json: "{}")              // /close i1 on retire (stop)
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        await app.startPlayback(itemID: "i1")
        #expect(app.playback.isPlaying == true)
        #expect(app.queue.isEmpty)

        await app.advanceToNext()

        #expect(app.nowPlayingItemID == nil)          // finished session retired
        #expect(app.playback.isPlaying == false)      // stopped, nothing new started
        // Only i1's /play was ever issued — the empty queue produced no advance play.
        let plays = await transport.recorded.compactMap { $0.url?.path }.filter { $0.contains("/play") }
        #expect(plays.count == 1)
    }

    /// The book-finished signal (`playback.onBookFinished`, emitted by PlayerEngine when the last
    /// track ends — see `PlaybackControllerTests.bookFinishedFiresOnlyOnLastItem`) is wired by
    /// `AppState` to `advanceToNext`. Firing it drains the queue front. (The PlayerEngine→AppState
    /// callback is proven in the engine suite; this proves AppState's end of the wire.)
    @Test func bookFinishedSignalTriggersAdvance() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play i1
        await transport.enqueue(status: 200, json: "{}")              // absorbers for the advance
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play i2 (advance target)
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        await app.startPlayback(itemID: "i1")
        app.addToQueue(itemID: "i2", title: "Second", author: "Auth")
        #expect(app.playback.onBookFinished != nil)   // AppState wired the signal in init

        // Fire the wired book-finished signal; it spawns the detached advance.
        app.playback.onBookFinished?()

        // Await the advance draining the front (the pop is synchronous once the Task runs).
        for _ in 0..<1000 where app.queue.entries.contains(where: { $0.itemID == "i2" }) {
            await Task.yield()
        }
        #expect(!app.queue.entries.contains { $0.itemID == "i2" })
    }

    /// CONCURRENCY REGRESSION (Task 8): two advances firing near-simultaneously — the book-finished
    /// signal racing a manual Play Next, or a double-tap — must consume EXACTLY ONE queued item and
    /// leave the other queued, never silently dropping it. RED without the first-advance-wins guard +
    /// peek-then-commit: the original code popped the front on EACH advance, but `startPlayback`'s
    /// own guard dropped the second, losing that popped item (queue ended empty, i3 gone).
    @Test func concurrentAdvanceDoesNotDropQueuedItem() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play i1
        await transport.enqueue(status: 200, json: "{}")              // absorbers for the ONE advance
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play i2 (the single advance)
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        await app.startPlayback(itemID: "i1")
        app.addToQueue(itemID: "i2", title: "Second", author: "Auth")
        app.addToQueue(itemID: "i3", title: "Third", author: "Auth")
        #expect(app.queue.entries.map(\.itemID) == ["i2", "i3"])

        // Fire two advances near-simultaneously. The first sets the in-flight flag before its first
        // await; the second bails at the guard, so the queue is peeked/consumed exactly once.
        async let a: Void = app.advanceToNext()
        async let b: Void = app.advanceToNext()
        _ = await (a, b)

        #expect(app.queue.entries.map(\.itemID) == ["i3"])   // i2 consumed ONCE; i3 REMAINS (not lost)
        #expect(app.nowPlayingItemID == "i2")
        // Exactly two /play requests total: i1's initial open + i2's single advance — no third.
        let plays = await transport.recorded.compactMap { $0.url?.path }.filter { $0.contains("/play") }
        #expect(plays.count == 2)
    }

    /// Removing a connection drops its queued entries (Task 8's removed-connection handling): a
    /// book queued from a connection that's then forgotten doesn't linger in the up-next queue.
    @Test func removeConnectionDropsItsQueuedEntries() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        app.addToQueue(itemID: "i9", title: "Queued", author: nil)
        #expect(app.queue.entries.count == 1)

        await app.removeConnection(cid)

        #expect(app.queue.isEmpty)   // the removed connection's queued entry was dropped
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
        // GatedTokenStore.save is non-throwing (only tokens(for:) gates); the concrete type here
        // (not the `throws`-declaring TokenStore existential) makes `try` a no-op the compiler
        // correctly flags.
        await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")
        let sockets = SocketConstructionCounter()
        let app = AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in sockets.record(); return FakeSocket() },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() }
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
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() }
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
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() }
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

    // MARK: - Connection epoch (M1c-a Task 1 — asymmetry fixes)

    /// Asymmetry fix A — an invalid-URL `connect()` must not stale a healthy active connection's
    /// in-flight probe. Activate `C1` with its `authorize()` parked on a `GatedTransport`; while the
    /// probe hangs, call `connect()` with a malformed URL string (fails `normalizedServerURL` and
    /// returns early). Because the epoch bump now lives BELOW URL validation, that early return
    /// leaves the epoch untouched — so when the gate opens the probe is still the current intent and
    /// brings `C1` online. Pre-fix, the top-of-`connect` bump would have staled the probe and left
    /// `C1` permanently offline.
    @Test func invalidURLConnectDoesNotStaleActiveProbe() async throws {
        let dir = makeTempDir()
        let transport = GatedTransport(gatePath: "/api/authorize")   // park the active connection's probe
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: dir, transport: transport, tokenStore: tokenStore)
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")

        await app.activateConnection("C1")   // returns; the probe is launched and parks on the gate
        while await transport.requestCount(pathContains: "/api/authorize") == 0 { await Task.yield() }
        #expect(app.isOnline == false)

        // A malformed URL fails validation and returns before any epoch bump or socket teardown.
        await app.connect(serverURL: "no-scheme-here", username: "root", password: "pw")
        #expect(app.errorMessage == "Invalid server URL")
        #expect(app.activeConnectionID == "C1")   // the rejected connect left the active id untouched

        // Release the gate: the probe is STILL the current intent (the invalid connect never bumped
        // the epoch), so it brings C1 online with a live socket.
        await transport.enqueue(status: 200, json: "{}")           // the probe's /api/authorize
        await transport.enqueue(status: 200, json: librariesOK)    // the probe's /libraries
        await transport.openGate()
        while !app.isOnline { await Task.yield() }
        #expect(app.isOnline == true)
        #expect(app.activeConnectionID == "C1")
    }

    /// Asymmetry fix B — a signOut whose owning-session retire is parked mid-await must not let its
    /// tail stomp a newer activation started during that await. Connect `A` and start playback (so
    /// `signOut(A)`'s retire does flush/close round-trips), gate `/close` so the retire parks, then
    /// activate `B` (bumps the epoch, brings B online with its own socket). Release the gate: the
    /// stale signOut tail no-ops its active-state teardown on the epoch guard, so B's
    /// activeConnectionID/isOnline/socket survive — while A is still genuinely signed out (its
    /// id-scoped bookkeeping — session retired, tokens cleared, badge set — still runs).
    @Test func signOutTailDoesNotStompNewerActivation() async throws {
        let dir = makeTempDir()
        let transport = GatedTransport(gatePath: "/close")   // park signOut's retire on the session close
        await transport.enqueue(status: 200, json: statusOK)          // A connect: /status
        await transport.enqueue(status: 200, json: loginOK)          // A connect: /login
        await transport.enqueue(status: 200, json: librariesOK)      // A connect: /libraries
        await transport.enqueue(status: 200, json: playSessionJSON)  // A: /play
        // Four 200s covering, in removeFirst order: a possible flush /sync, B probe /api/authorize,
        // B probe /libraries, and the gated /close (served last on gate open). B comes online right
        // after its authorize regardless of what /libraries decodes, so plain "{}" bodies suffice.
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: "{}")
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: dir, transport: transport, tokenStore: tokenStore)
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        let aID = try #require(app.activeConnectionID)
        await app.startPlayback(itemID: "i1")
        #expect(app.playback.isPlaying == true)

        // The newer connection, seeded with tokens so its probe comes online with a socket.
        try app.cache.upsertConnection(CachedConnection(id: "B", address: "http://b:13378", name: "B",
                                                        username: "root", authMethod: "local", sortIndex: 1))
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "B")

        // Sign out A (owns playback): its retire parks on the gated /close.
        let signOutTask = Task { await app.signOut(connectionID: aID) }
        while await transport.requestCount(pathContains: "/close") == 0 { await Task.yield() }

        // While the signOut tail is parked, activate B — bumps the epoch and brings B online.
        await app.activateConnection("B")
        #expect(app.activeConnectionID == "B")
        while !app.isOnline { await Task.yield() }   // B's probe consumed authorize, its socket is up

        // Release /close: the retire completes and the stale signOut tail runs against a superseded epoch.
        await transport.openGate()
        await signOutTask.value

        #expect(app.activeConnectionID == "B")               // newer activation survives
        #expect(app.isOnline == true)                        // B's online/socket not torn down by the tail
        #expect(app.playback.isPlaying == false)             // A's owning session was retired
        #expect(app.needsSignIn.contains(aID))               // A genuinely signed out
        #expect(await tokenStore.tokens(for: aID) == nil)    // A's tokens cleared
        #expect(!app.needsSignIn.contains("B"))              // B is online, not badged
    }

    /// Asymmetry fix B, the case that genuinely EXERCISES the epoch guard (the sibling test above,
    /// with two distinct connections, is already covered by the pre-existing `activeConnectionID == id`
    /// check). Sign out A while it OWNS playback (retire parks on the gated `/close`), then re-activate
    /// the SAME connection A — its probe brings A back online with a fresh socket/client. When the
    /// gate opens, the stale signOut tail resumes: `activeConnectionID == id` is STILL true (it's A),
    /// so ONLY the epoch guard stops the tail from tearing down the re-activation's live socket/client.
    /// Asserts survival invariants only (the token-clear residual is a known follow-up and would
    /// muddy token/badge assertions here).
    ///
    /// Strict RED→GREEN: deleting `connectionEpoch == myEpoch` from `performSignOut`'s tail guard
    /// makes this FAIL (the tail stomps A) — confirmed during implementation.
    @Test func signOutTailDoesNotStompSameIdReactivation() async throws {
        final class SocketRecorder { private(set) var all: [FakeSocket] = []; func record(_ s: FakeSocket) { all.append(s) } }

        let dir = makeTempDir()
        let transport = GatedTransport(gatePath: "/close")   // park signOut's retire on the session close
        await transport.enqueue(status: 200, json: statusOK)          // A connect: /status
        await transport.enqueue(status: 200, json: loginOK)          // A connect: /login
        await transport.enqueue(status: 200, json: librariesOK)      // A connect: /libraries
        await transport.enqueue(status: 200, json: playSessionJSON)  // A: /play
        // Four 200s covering, in removeFirst order: a possible flush /sync, A re-activation probe
        // /api/authorize, its /libraries, and the gated /close (served last on gate open). The
        // re-activation comes online right after its authorize, so plain "{}" bodies suffice.
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: "{}")
        await transport.enqueue(status: 200, json: "{}")
        let tokenStore = InMemoryTokenStore()
        let sockets = SocketRecorder()
        let app = AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in let s = FakeSocket(); sockets.record(s); return s },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() }
        )
        app.playback.muted = true

        // Connect A (saves A's tokens, stands up socket #1) and start playback so signOut retires.
        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        let aID = try #require(app.activeConnectionID)
        await app.startPlayback(itemID: "i1")
        #expect(app.playback.isPlaying == true)

        // Sign out A (owns playback): its retire parks on the gated /close.
        let signOutTask = Task { await app.signOut(connectionID: aID) }
        while await transport.requestCount(pathContains: "/close") == 0 { await Task.yield() }

        // While the signOut tail is parked, RE-ACTIVATE the same id A — bumps the epoch; its probe
        // brings A back online with socket #2.
        await app.activateConnection(aID)
        #expect(app.activeConnectionID == aID)
        while !app.isOnline { await Task.yield() }   // A's re-activation probe: authorize + startSocket
        #expect(sockets.all.count == 2)              // connect socket + re-activation socket

        // Release /close: the retire completes and the stale signOut tail resumes with
        // `activeConnectionID == aID` STILL true — only the epoch guard saves the re-activation.
        await transport.openGate()
        await signOutTask.value

        // Survival invariants: the re-activation's socket/client/online state are untouched.
        #expect(sockets.all.last?.stopCount == 0)    // re-activation socket NOT torn down by the tail
        #expect(app.isOnline == true)                // isOnline not flipped off
        #expect(app.client != nil)                   // client not nilled
        #expect(app.activeConnectionID == aID)       // still A
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
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() }
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

    // MARK: - Per-item socket patch + uncapped reconciliation (M1c-a Task 3)

    /// `apply(.itemChanged(id:))` patches exactly ONE row via `ABSClient.item(id:)` — no coarse
    /// full-library re-page. Cache seeded with two items in the same library; a socket
    /// `item_updated` for item "a" fetches `/api/items/a`, upserts just that row (with the
    /// fresh title/author/duration from the patch response), and leaves item "b" untouched.
    /// Critically, no `/api/libraries/:id/items` request is made at all — the old coarse
    /// `refreshItems` path is gone for this event.
    @Test func itemChangedPatchesSingleRowNotFullRefresh() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "a", connectionID: cid, libraryID: "lib1", title: "Old A",
                        authorName: "Old Author A", duration: 1, updatedAt: 1),
             CachedItem(id: "b", connectionID: cid, libraryID: "lib1", title: "Old B",
                        authorName: "Old Author B", duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        await transport.enqueue(status: 200, json: #"""
            {"id":"a","libraryId":"lib1","updatedAt":42,"media":{"duration":99,"metadata":{"title":"Patched A","authorName":"New Author A"}}}
            """#)

        await app.apply(.itemChanged(id: "a"))

        let items = try app.cache.items(connectionID: cid, libraryID: "lib1")
        let a = items.first { $0.id == "a" }
        let b = items.first { $0.id == "b" }
        #expect(a?.title == "Patched A")
        #expect(a?.authorName == "New Author A")
        #expect(a?.duration == 99)
        #expect(b?.title == "Old B")                // untouched
        #expect(b?.authorName == "Old Author B")    // untouched

        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.filter { $0 == "/api/items/a" }.count == 1)          // exactly one patch fetch
        #expect(!paths.contains { $0.contains("/libraries/") && $0.contains("/items") })  // NO full re-page
    }

    /// A completed MULTI-page fetch (not just the single-page case `completedRefreshReconciles`
    /// already covers) still reconciles via `replaceItems` — the accumulate-across-pages loop
    /// isn't capped short of completion. Three pages, total spanning all of them; a
    /// previously-cached stale row (absent from every fresh page) is gone afterward, and every
    /// fresh row from all three pages is present.
    @Test func largeLibraryReconcilesWithoutCap() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "stale", connectionID: cid, libraryID: "lib1", title: "Stale",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        // Three pages, total = 3 (one fresh item per page) — none of them is "stale".
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 3, results: ["i0"]))
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 3, results: ["i1"]))
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 3, results: ["i2"]))

        try await app.refreshItems(libraryID: "lib1")

        let items = try app.cache.items(connectionID: cid, libraryID: "lib1")
        #expect(Set(items.map(\.id)) == Set(["i0", "i1", "i2"]))   // every fresh page's item present
        #expect(!items.contains { $0.id == "stale" })              // stale row reconciled away
        let itemsRequests = await transport.recorded.filter { ($0.url?.path ?? "").contains("/items") }
        #expect(itemsRequests.count == 3)                          // all three pages actually fetched
    }

    /// The definitive cap-raise proof: a page-through that EXCEEDS the old 20-page hard cap.
    /// 25 pages (one item each), `total = 25` spanning all of them, plus a previously-cached
    /// stale row absent from every fresh page. After the completed 25-page fetch, `replaceItems`
    /// reconciled the stale row away and all 25 fresh rows are present.
    ///
    /// RED against the OLD 20-page cap (`for page in 0..<20`): only pages 0–19 (20 items) would be
    /// fetched, so `accumulated (20) < total (25)` — the loop ends WITHOUT `completed`, falls to
    /// the per-page `upsertItemsPage` branch (never `replaceItems`), and the stale row SURVIVES.
    /// Both the "stale gone" and "25 requests" assertions below would fail. GREEN now that the
    /// cap is a generous 200-page safety bound: all 25 pages are fetched, the fetch completes, and
    /// `replaceItems` reconciles. (The 3-page sibling above passes against the old cap too, so it
    /// alone does NOT prove the cap was raised — this one does.)
    @Test func largeLibraryReconcilesBeyondTwentyPages() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "stale", connectionID: cid, libraryID: "lib1", title: "Stale",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        // 25 pages, one fresh item each, total = 25 — spans well past the old 20-page cap.
        let freshIDs = (0..<25).map { "m\($0)" }
        for id in freshIDs {
            await transport.enqueue(status: 200, json: itemsPageJSON(total: 25, results: [id]))
        }

        try await app.refreshItems(libraryID: "lib1")

        let items = try app.cache.items(connectionID: cid, libraryID: "lib1")
        #expect(Set(items.map(\.id)) == Set(freshIDs))             // every one of the 25 pages' items present
        #expect(!items.contains { $0.id == "stale" })             // reconciled away — proves replaceItems ran
        let itemsRequests = await transport.recorded.filter { ($0.url?.path ?? "").contains("/items") }
        #expect(itemsRequests.count == 25)                         // all 25 pages fetched (old cap stopped at 20)
    }

    /// `apply(.itemsChanged(ids:))` below the batch threshold patches EACH id individually via
    /// `ABSClient.item(id:)` — no coarse full-library re-page. Three ids → exactly three
    /// `/api/items/:id` requests, no `/api/libraries/:id/items` full-refresh, and all three cached
    /// rows updated to their patched titles.
    @Test func itemsChangedPatchesEachBelowThreshold() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.upsertItemsPage(
            [CachedItem(id: "x", connectionID: cid, libraryID: "lib1", title: "Old X",
                        authorName: nil, duration: 1, updatedAt: 1),
             CachedItem(id: "y", connectionID: cid, libraryID: "lib1", title: "Old Y",
                        authorName: nil, duration: 1, updatedAt: 1),
             CachedItem(id: "z", connectionID: cid, libraryID: "lib1", title: "Old Z",
                        authorName: nil, duration: 1, updatedAt: 1)],
            connectionID: cid, libraryID: "lib1")
        // One expanded-detail response per id, consumed FIFO in the ["x","y","z"] iteration order.
        for id in ["x", "y", "z"] {
            await transport.enqueue(status: 200, json: #"""
                {"id":"\#(id)","libraryId":"lib1","updatedAt":7,"media":{"duration":5,"metadata":{"title":"Patched \#(id)","authorName":null}}}
                """#)
        }

        await app.apply(.itemsChanged(ids: ["x", "y", "z"]))

        let items = try app.cache.items(connectionID: cid, libraryID: "lib1")
        #expect(items.first { $0.id == "x" }?.title == "Patched x")
        #expect(items.first { $0.id == "y" }?.title == "Patched y")
        #expect(items.first { $0.id == "z" }?.title == "Patched z")
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.filter { $0.hasPrefix("/api/items/") }.count == 3)                 // three single patches
        #expect(!paths.contains { $0.contains("/libraries/") && $0.contains("/items") }) // NO full re-page
    }

    /// `apply(.itemsChanged(ids:))` ABOVE the batch threshold (> 50 ids) falls back to ONE full
    /// `refreshItems` of the active library rather than firing 51 single-item fetches — a bulk
    /// edit is cheaper and cleaner to reconcile in one paged pass. `activeLibraryID` is primed by
    /// an initial `refreshItems`; the 51-id event then triggers exactly one more `/items?page`
    /// request and ZERO `/api/items/:id` single fetches.
    @Test func itemsChangedFallsBackToFullRefreshAboveThreshold() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(transportProvider: { transport }, dir: makeTempDir())

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        _ = try #require(app.activeConnectionID)
        // Prime activeLibraryID with an initial open (one /items page).
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 1, results: ["seed"]))
        try await app.refreshItems(libraryID: "lib1")
        let itemsRequestsBefore = await transport.recorded.filter { ($0.url?.path ?? "").contains("/libraries/") }.count
        // The fallback refresh's page.
        await transport.enqueue(status: 200, json: itemsPageJSON(total: 1, results: ["seed"]))

        await app.apply(.itemsChanged(ids: (0..<51).map { "id\($0)" }))

        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(!paths.contains { $0.hasPrefix("/api/items/") })          // NOT 51 single fetches
        let itemsRequestsAfter = paths.filter { $0.contains("/libraries/") && $0.contains("/items") }.count
        #expect(itemsRequestsAfter == itemsRequestsBefore + 1)            // exactly one full-refresh page
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
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() })
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
    /// defaults — 1.0× and `AppState.defaultSkipInterval` (30s, the Task-4 reconciled single source
    /// of truth) — not `UserDefaults`' bare-key zero value.
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
        #expect(app.playback.skipInterval == AppState.defaultSkipInterval)
    }

    // MARK: - Task 7: per-book playback-rate persistence (v3)

    /// A book with a stored per-book rate (`cache.setPlaybackRate`, Task 7's `v3` table) resumes at
    /// THAT rate on `startPlayback`, overriding the global default setting.
    @Test func storedPerBookRateOverridesGlobalDefault() async throws {
        let restoreRate = snapshotDefault(AppState.defaultRateKey)
        defer { restoreRate() }
        UserDefaults.standard.set(1.0, forKey: AppState.defaultRateKey)   // distinct from the per-book rate

        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.setPlaybackRate(1.5, connectionID: cid, itemID: "i1")   // pre-existing per-book pref

        await app.startPlayback(itemID: "i1")

        #expect(app.playback.rate == 1.5)   // per-book rate wins over the 1.0x global default
    }

    /// The sibling: a book with NO stored rate falls back to the global default, unaffected by a
    /// DIFFERENT book's per-book preference (scoped by itemID, not just connection).
    @Test func bookWithoutStoredRateFallsBackToGlobalDefault() async throws {
        let restoreRate = snapshotDefault(AppState.defaultRateKey)
        defer { restoreRate() }
        UserDefaults.standard.set(1.75, forKey: AppState.defaultRateKey)

        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try app.cache.setPlaybackRate(1.5, connectionID: cid, itemID: "some-other-book")

        await app.startPlayback(itemID: "i1")   // no per-book rate stored for "i1"

        #expect(app.playback.rate == 1.75)   // global default applies
    }

    /// `AppState.setPlaybackRate` (the SpeedControl write path) both applies the rate to the live
    /// `PlaybackController` immediately AND persists it as this (connection, item)'s per-book pref —
    /// so a later `startPlayback` of the SAME book resumes at it.
    @Test func setPlaybackRateAppliesLiveAndPersistsPerBook() async throws {
        let restoreRate = snapshotDefault(AppState.defaultRateKey)
        defer { restoreRate() }
        UserDefaults.standard.set(1.0, forKey: AppState.defaultRateKey)

        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // first open
        await transport.enqueue(status: 200, json: "{}")              // possible flush /sync on retire
        await transport.enqueue(status: 200, json: "{}")              // /close on retire
        await transport.enqueue(status: 200, json: playSessionJSON)   // re-open
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        await app.startPlayback(itemID: "i1")
        #expect(app.playback.rate == 1.0)

        app.setPlaybackRate(1.5)
        #expect(app.playback.rate == 1.5)                                          // applied live
        #expect(try app.cache.playbackRate(connectionID: cid, itemID: "i1") == 1.5) // persisted per-book

        await app.startPlayback(itemID: "i1")   // re-open the SAME book
        #expect(app.playback.rate == 1.5)       // resumes at the persisted per-book rate
    }

    // MARK: - Offline playback from downloaded files (M2a Task 5)

    /// Builds an `AppState` with an isolated temp downloads root, so an offline test can seed a
    /// download's file at a path the `DownloadCoordinator` will resolve to.
    private func makeAppWithDownloads(dir: URL, downloadsRoot: URL,
                                      transport: Transport, tokenStore: any TokenStore) -> AppState {
        AppState(
            transportProvider: { transport },
            cacheDirectory: dir,
            socketFactory: { _, _ in FakeSocket() },
            tokenStore: tokenStore,
            oidcTransportProvider: { transport },
            downloadManagerProvider: { FakeDownloadManaging() },
            downloadsRoot: downloadsRoot)
    }

    /// Seed a FULLY-downloaded single-file book: the pinned browse row (title/author) + detail
    /// (chapters), an optional resume `cachedProgress`, a `.downloaded` parent + file row, and the
    /// fake audio file on disk at the coordinator's resolved path. Returns the on-disk `file://` URL.
    @discardableResult
    private func seedDownloadedBook(
        _ app: AppState, connectionID: String, itemID: String, downloadsRoot: URL,
        duration: Double, currentTime: Double, title: String = "Downloaded Book",
        author: String = "Local Author", chapters: [CachedChapter] = [],
        nilFileDuration: Bool = false
    ) throws -> URL {
        try app.cache.upsertItemsPage(
            [CachedItem(id: itemID, connectionID: connectionID, libraryID: "L1",
                        title: title, authorName: author, duration: duration, updatedAt: 1)],
            connectionID: connectionID, libraryID: "L1")
        try app.cache.upsertItemDetail(
            CachedItemDetail(connectionID: connectionID, itemID: itemID, chapters: chapters))
        if currentTime > 0 {
            try app.cache.upsertProgress(CachedProgress(
                connectionID: connectionID, itemID: itemID, currentTime: currentTime,
                isFinished: false, lastUpdate: 1))
        }
        let rel = "\(connectionID)/\(itemID)/_/track-0.mp3"
        try app.cache.upsertDownload(CachedDownload(
            connectionID: connectionID, itemID: itemID, state: DownloadCoordinator.State.downloaded,
            receivedBytes: 100, totalBytes: 100, updatedAt: 1))
        try app.cache.upsertDownloadFile(CachedDownloadFile(
            connectionID: connectionID, itemID: itemID, trackIndex: 0, ino: "111",
            localRelativePath: rel, receivedBytes: 100, totalBytes: 100,
            state: DownloadCoordinator.State.downloaded, mimeType: "audio/mpeg",
            durationSeconds: nilFileDuration ? nil : duration))
        let fileURL = downloadsRoot.appending(path: rel)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake audio".utf8).write(to: fileURL)
        return fileURL
    }

    /// Seed a FULLY-downloaded single-file podcast EPISODE (episodeID set): the pinned `cachedEpisode`
    /// (title) + detail (chapters), an optional resume `cachedProgress` on the 3-part episode key, a
    /// `.downloaded` parent + file row, and the fake audio file on disk at the coordinator's resolved
    /// episode path (`…/<itemID>/<episodeID>/track-0.mp3`). Returns the on-disk `file://` URL.
    @discardableResult
    private func seedDownloadedEpisode(
        _ app: AppState, connectionID: String, itemID: String, episodeID: String, downloadsRoot: URL,
        duration: Double, currentTime: Double, episodeTitle: String = "Episode One",
        chapters: [CachedChapter] = []
    ) throws -> URL {
        try app.cache.upsertEpisodes(
            [CachedEpisode(connectionID: connectionID, itemID: itemID, episodeID: episodeID,
                           title: episodeTitle, durationSeconds: duration)],
            connectionID: connectionID, itemID: itemID)
        try app.cache.upsertItemDetail(
            CachedItemDetail(connectionID: connectionID, itemID: itemID, chapters: chapters))
        if currentTime > 0 {
            try app.cache.upsertProgress(CachedProgress(
                connectionID: connectionID, itemID: itemID, episodeID: episodeID,
                currentTime: currentTime, isFinished: false, lastUpdate: 1))
        }
        let rel = "\(connectionID)/\(itemID)/\(episodeID)/track-0.mp3"
        try app.cache.upsertDownload(CachedDownload(
            connectionID: connectionID, itemID: itemID, episodeID: episodeID,
            state: DownloadCoordinator.State.downloaded, receivedBytes: 100, totalBytes: 100, updatedAt: 1))
        try app.cache.upsertDownloadFile(CachedDownloadFile(
            connectionID: connectionID, itemID: itemID, episodeID: episodeID, trackIndex: 0,
            ino: "222", localRelativePath: rel, receivedBytes: 100, totalBytes: 100,
            state: DownloadCoordinator.State.downloaded, mimeType: "audio/mpeg",
            durationSeconds: duration))
        let fileURL = downloadsRoot.appending(path: rel)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake audio".utf8).write(to: fileURL)
        return fileURL
    }

    /// THE offline-playback deliverable: a FULLY-downloaded item plays from LOCAL `file://` URLs with
    /// ZERO network — no `/play` session opened — carrying `playMethod: local`, the cached chapters,
    /// and the `cachedProgress` resume position, wired into the same now-playing state as streaming.
    @Test func offlinePlaybackUsesLocalFilesWithNoPlayRequest() async throws {
        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()          // nothing queued: a stream attempt would be visible
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        let chapters = [CachedChapter(id: 0, start: 0, end: 60, title: "Ch1"),
                        CachedChapter(id: 1, start: 60, end: 120, title: "Ch2")]
        let fileURL = try seedDownloadedBook(app, connectionID: "C1", itemID: "dl1",
                                             downloadsRoot: downloadsRoot, duration: 120,
                                             currentTime: 42, chapters: chapters)

        await app.activateConnection("C1")       // no tokens → offline, client nil
        #expect(app.activeConnectionID == "C1")
        #expect(app.isOnline == false)

        await app.startPlayback(itemID: "dl1")

        // NOT a single request reached the server — no /play, no anything.
        #expect(await transport.recorded.isEmpty)
        // The LOCAL file was loaded (a file:// URL at the resolved downloads path).
        #expect(app.playback.loadedTrackURLs == [fileURL])
        #expect(app.playback.loadedTrackURLs.allSatisfy { $0.isFileURL })
        // Local play method (ABS PlayMethod.LOCAL == 3).
        #expect(app.playback.playMethod == LocalPlaybackSession.playMethodLocal)
        // Now-playing state wired exactly like the streaming path.
        #expect(app.nowPlayingItemID == "dl1")
        #expect(app.nowPlayingEpisodeID == nil)
        #expect(app.nowPlayingChapters.map(\.id) == [0, 1])   // chapters from the pinned cache detail
        #expect(app.playback.isPlaying == true)
        // Resumed at the cached progress position.
        #expect(app.playback.globalTime == 42)
    }

    /// The SELECTION RULE's other half: a NON-downloaded item still STREAMS (opens a `/play` session)
    /// — the existing path is unregressed by the offline branch.
    @Test func nonDownloadedItemStillStreams() async throws {
        let dir = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // /play for i1
        let app = makeApp(dir: dir, transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)

        await app.startPlayback(itemID: "i1")    // i1 has no download → must stream

        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.hasSuffix("/items/i1/play") })
        #expect(app.nowPlayingItemID == "i1")
        #expect(app.playback.playMethod == 0)                          // streamed (envelope playMethod 0)
        #expect(app.playback.loadedTrackURLs.allSatisfy { !$0.isFileURL })   // server URLs, not local
    }

    /// The guards are REUSED, not forked: while a streaming start is in-flight (parked on the /play
    /// gate, `isStartingPlayback` held), a racing OFFLINE start of a downloaded item is DROPPED by the
    /// SAME reentrancy guard — it never sneaks past to load local audio.
    @Test func offlineStartIsDroppedByTheSharedReentrancyGuard() async throws {
        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = GatedTransport(gatePath: "/play")
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 200, json: loginOK)
        await transport.enqueue(status: 200, json: librariesOK)
        await transport.enqueue(status: 200, json: playSessionJSON)   // i1 /play (released after gate)
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)
        let connID = try #require(app.activeConnectionID)
        try seedDownloadedBook(app, connectionID: connID, itemID: "dl2",
                               downloadsRoot: downloadsRoot, duration: 100, currentTime: 0)

        // First tap: STREAMING i1, parked on the /play gate (guard held).
        let first = Task { await app.startPlayback(itemID: "i1") }
        while await transport.requestCount(pathContains: "/play") == 0 { await Task.yield() }

        // Second tap while the first is in-flight: an OFFLINE downloaded item — dropped by the guard.
        await app.startPlayback(itemID: "dl2")
        #expect(app.nowPlayingItemID != "dl2")
        #expect(app.playback.loadedTrackURLs.isEmpty)   // nothing loaded — i1 is still gated

        await transport.openGate()
        await first.value
        #expect(await transport.requestCount(pathContains: "/play") == 1)   // only the first start ran
        #expect(app.nowPlayingItemID == "i1")
    }

    /// Task-5 progress scope (local only): the OFFLINE session's `onSyncDue` writes `cachedProgress`
    /// LOCALLY on each due tick / flush — with NO network — so the resume + UI reflect an offline
    /// listen. (Task 6 fills the `onOfflineProgressAccrued` seam for server sync-back.)
    @Test func offlineOnSyncDueWritesLocalProgressWithoutNetwork() async throws {
        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try seedDownloadedBook(app, connectionID: "C1", itemID: "dl1",
                               downloadsRoot: downloadsRoot, duration: 120, currentTime: 0)
        await app.activateConnection("C1")
        await app.startPlayback(itemID: "dl1")
        #expect(app.playback.playMethod == LocalPlaybackSession.playMethodLocal)

        // Also proves the Task-6 seam is invoked with the same payload.
        var seamPayload: SyncPayload?
        app.onOfflineProgressAccrued = { _, _, payload in seamPayload = payload }

        // Drive the offline sync sink directly (the exact closure a tick / pause / retire invokes).
        let synced = await app.playback.onSyncDue?(SyncPayload(currentTime: 63.5, timeListened: 20))
        #expect(synced == true)

        let progress = try #require((try? app.cache.progress(connectionID: "C1", itemID: "dl1")) ?? nil)
        #expect(progress.currentTime == 63.5)      // offline listen reflected locally
        #expect(seamPayload?.currentTime == 63.5)  // Task-6 seam saw it too
        #expect(await transport.recorded.isEmpty)  // NO network
    }

    /// The offline path for a downloaded EPISODE (episodeID != ""): plays from the LOCAL episode file
    /// with ZERO network — NO `/play/:episodeId` — carrying `playMethod: local`, the episode's title
    /// (from `cachedEpisode`), the podcast title as the now-playing author (`podcastTitle` →
    /// `authorOverride`), and the episode's own `cachedProgress` resume position. Exercises the
    /// episode branch of `localPlaybackSource` (nowPlayingEpisodeID + episode-title assertions below
    /// hold ONLY on that branch — the book branch would leave the episode id nil and the author blank).
    @Test func offlineEpisodePlaybackUsesLocalFileWithNoPlayRequest() async throws {
        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        let chapters = [CachedChapter(id: 0, start: 0, end: 200, title: "Part 1")]
        let fileURL = try seedDownloadedEpisode(app, connectionID: "C1", itemID: "pod1", episodeID: "ep1",
                                                downloadsRoot: downloadsRoot, duration: 400,
                                                currentTime: 90, episodeTitle: "Episode One", chapters: chapters)

        await app.activateConnection("C1")       // no tokens → offline, client nil
        #expect(app.isOnline == false)

        await app.startPlayback(itemID: "pod1", episodeId: "ep1", podcastTitle: "Colophon Test Podcast")

        // NO server /play/:episodeId — no request at all.
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(!paths.contains { $0.contains("/play") })
        #expect(await transport.recorded.isEmpty)
        // Loaded the LOCAL episode file.
        #expect(app.playback.loadedTrackURLs == [fileURL])
        #expect(app.playback.loadedTrackURLs.allSatisfy { $0.isFileURL })
        #expect(app.playback.playMethod == LocalPlaybackSession.playMethodLocal)
        // Episode now-playing wiring — the episode branch.
        #expect(app.nowPlayingItemID == "pod1")
        #expect(app.nowPlayingEpisodeID == "ep1")
        #expect(app.nowPlayingChapters.map(\.id) == [0])
        #expect(app.playback.title == "Episode One")             // title from cachedEpisode
        #expect(app.playback.author == "Colophon Test Podcast")  // podcastTitle → authorOverride
        #expect(app.playback.isPlaying == true)
        #expect(app.playback.globalTime == 90)                   // resume from the episode's cachedProgress
    }

    /// Robustness of the SELECTION RULE: a fully-downloaded item whose per-file duration is MISSING
    /// (server omitted `audioFile.duration` → a nil `durationSeconds` → a zero-length/broken local
    /// timeline) STREAMS when a client is available, rather than playing a broken local timeline. The
    /// offline degraded path (no client) is intentionally not taken here — this asserts the online
    /// fallback.
    @Test func downloadedItemWithMissingDurationStreamsWhenOnline() async throws {
        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: playSessionJSON)   // the streaming fallback /play
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true

        await app.connect(serverURL: "http://a:13378", username: "root", password: "pw")
        #expect(app.phase == .connected)
        let connID = try #require(app.activeConnectionID)
        // Fully downloaded + on disk, but its file has NO duration → a broken local timeline.
        try seedDownloadedBook(app, connectionID: connID, itemID: "dlN", downloadsRoot: downloadsRoot,
                               duration: 100, currentTime: 30, nilFileDuration: true)

        await app.startPlayback(itemID: "dlN")

        // Online + broken local timeline → fall back to STREAMING (correct server-computed offsets).
        let paths = await transport.recorded.compactMap { $0.url?.path }
        #expect(paths.contains { $0.hasSuffix("/items/dlN/play") })
        #expect(app.nowPlayingItemID == "dlN")
        #expect(app.playback.playMethod == 0)                            // streamed, not local
        #expect(app.playback.loadedTrackURLs.allSatisfy { !$0.isFileURL })   // server URLs, not file
    }

    // MARK: - Local-session sync-back + reachability (M2a Task 6)

    /// Seed a SEALED (not currently-playing) pending offline session directly into the store.
    @discardableResult
    private func seedLocalSession(
        _ app: AppState, id: String, connectionID: String, itemID: String, episodeID: String? = nil,
        timeListening: Double, currentTime: Double = 0, duration: Double = 100,
        startedAt: Int = 1, updatedAt: Int = 1
    ) throws -> CachedLocalSession {
        let session = CachedLocalSession(
            id: id, connectionID: connectionID, itemID: itemID, episodeID: episodeID,
            mediaType: (episodeID ?? "").isEmpty ? "book" : "podcast",
            currentTime: currentTime, timeListening: timeListening, duration: duration,
            startedAt: startedAt, updatedAt: updatedAt,
            deviceId: "dev", clientName: "Colophon", clientVersion: "1.0", manufacturer: "Apple", model: "iPhone")
        try app.cache.upsertLocalSession(session)
        return session
    }

    /// The `timeListening` values of the sessions in the last `POST /api/session/local-all` body
    /// recorded by a `GatedTransport` (proves what actually reached the server).
    private func lastLocalAllTimeListening(_ transport: GatedTransport) async -> [String: Double] {
        let reqs = await transport.recordedRequests(pathContains: "session/local-all")
        guard let body = reqs.last?.httpBody,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return [:] }
        var out: [String: Double] = [:]
        for s in sessions {
            if let id = s["id"] as? String, let tl = s["timeListening"] as? Double { out[id] = tl }
        }
        return out
    }

    /// Offline ticks ACCUMULATE into ONE `cachedLocalSession` row (timeListening sums the per-tick
    /// deltas — never resets, never doubles); a SECOND offline session for the SAME item is a NEW row.
    @Test func offlineTicksAccrueOneRowAccumulatingSecondSessionIsNewRow() async throws {
        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try seedDownloadedBook(app, connectionID: "C1", itemID: "dl1",
                               downloadsRoot: downloadsRoot, duration: 120, currentTime: 0)
        await app.activateConnection("C1")
        await app.startPlayback(itemID: "dl1")
        #expect(app.playback.playMethod == LocalPlaybackSession.playMethodLocal)

        _ = await app.playback.onSyncDue?(SyncPayload(currentTime: 30, timeListened: 10))
        _ = await app.playback.onSyncDue?(SyncPayload(currentTime: 50, timeListened: 15))

        var rows = try app.cache.localSessions(connectionID: "C1")
        #expect(rows.count == 1)                       // ONE row for the session
        #expect(rows[0].timeListening == 25)           // 10 + 15 accumulated (not 15, not 50)
        #expect(rows[0].currentTime == 50)
        #expect(rows[0].itemID == "dl1")
        #expect(await transport.recorded.isEmpty)      // NO network

        // Seal the session and start a fresh offline playback of the SAME item → a NEW row.
        await app.closeCurrentSession()
        await app.startPlayback(itemID: "dl1")
        _ = await app.playback.onSyncDue?(SyncPayload(currentTime: 12, timeListened: 5))

        rows = try app.cache.localSessions(connectionID: "C1")
        #expect(rows.count == 2)                                       // a distinct second row
        #expect(rows.map(\.timeListening).sorted() == [5, 25])         // the first row untouched at 25
    }

    /// The reconnect reconcile, EXACT spec order: `GET /api/me` last-write-wins (newer SERVER
    /// progress wins locally, older is kept) → `POST /api/session/local-all` the pending sessions →
    /// PRUNE ONLY rows whose `success == true`; a `success == false` row STAYS pending (never dropped).
    @Test func reconnectReconcileServerNewerWinsPushesPrunesSuccessKeepsFailure() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)

        // Local progress: A is OLDER than the server (server should win); B is NEWER (local kept).
        try app.cache.upsertProgress(CachedProgress(connectionID: cid, itemID: "A", currentTime: 10,
                                                    isFinished: false, lastUpdate: 100))
        try app.cache.upsertProgress(CachedProgress(connectionID: cid, itemID: "B", currentTime: 88,
                                                    isFinished: false, lastUpdate: 500))
        try seedLocalSession(app, id: "S1", connectionID: cid, itemID: "A", timeListening: 40)
        try seedLocalSession(app, id: "S2", connectionID: cid, itemID: "B", timeListening: 30)

        await transport.enqueue(status: 200, json: #"""
        {"id":"root","username":"root","mediaProgress":[
          {"libraryItemId":"A","episodeId":null,"currentTime":55,"isFinished":false,"lastUpdate":200},
          {"libraryItemId":"B","episodeId":null,"currentTime":20,"isFinished":false,"lastUpdate":300}
        ]}
        """#)
        await transport.enqueue(status: 200, json: #"""
        {"results":[{"id":"S1","success":true},{"id":"S2","success":false,"error":"Media item not found"}]}
        """#)

        await app.reconcileOnReconnect()

        // (a) last-write-wins: A took the server's newer value; B kept its newer local value.
        #expect(try app.cache.progress(connectionID: cid, itemID: "A")?.currentTime == 55)
        #expect(try app.cache.progress(connectionID: cid, itemID: "A")?.lastUpdate == 200)
        #expect(try app.cache.progress(connectionID: cid, itemID: "B")?.currentTime == 88)   // local kept
        // (b) local-all POSTed with BOTH pending sessions.
        let localAll = await transport.recorded.first { ($0.url?.path ?? "").contains("session/local-all") }
        let body = try #require(localAll?.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let ids = Set(((obj["sessions"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        #expect(ids == ["S1", "S2"])
        // (c) prune ONLY the success — the failure STAYS pending.
        #expect(try app.cache.localSession(id: "S1") == nil)        // synced → pruned
        #expect(try app.cache.localSession(id: "S2") != nil)        // rejected → kept (never dropped)
        #expect(app.isOnline == true)                               // me() answered → online
    }

    /// ADVERSARIAL CONCURRENCY (the guard, RED-verified by dropping it): a tick landing DURING a
    /// reconcile is neither LOST nor DUPLICATED. The currently-playing offline session accrues a tick
    /// while `local-all` is parked mid-reconcile; because the live session is never pruned (and a
    /// row changed mid-reconcile is never pruned), its accrued tail survives — and a later reconcile
    /// pushes the correct SINGLE total, never double-counted.
    @Test func tickLandingMidReconcileIsNeitherLostNorDuplicated() async throws {
        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = GatedTransport(gatePath: "session/local-all")
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 200, json: loginOK)
        await transport.enqueue(status: 200, json: librariesOK)
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        #expect(app.isOnline == true)

        // Downloaded book plays from LOCAL files even while online (downloads-first) → a live offline
        // session accruing on the SAME connection that now has a live client.
        try seedDownloadedBook(app, connectionID: cid, itemID: "dl1",
                               downloadsRoot: downloadsRoot, duration: 120, currentTime: 0)
        await app.startPlayback(itemID: "dl1")
        #expect(app.playback.playMethod == LocalPlaybackSession.playMethodLocal)
        _ = await app.playback.onSyncDue?(SyncPayload(currentTime: 30, timeListened: 20))   // accrue 20
        let sid = try #require(try app.cache.localSessions(connectionID: cid).first).id
        #expect(try app.cache.localSession(id: sid)?.timeListening == 20)

        // me() (empty) then local-all (parked on the gate).
        await transport.enqueue(status: 200, json: #"{"id":"root","username":"root","mediaProgress":[]}"#)
        await transport.enqueue(status: 200, json: #"{"results":[{"id":"\#(sid)","success":true}]}"#)

        let reconcile = Task { await app.reconcileOnReconnect() }
        while await transport.requestCount(pathContains: "session/local-all") == 0 { await Task.yield() }

        // A tick lands mid-reconcile (local-all still parked): accrue +5 onto the live session.
        _ = await app.playback.onSyncDue?(SyncPayload(currentTime: 35, timeListened: 5))

        await transport.openGate()
        await reconcile.value

        // The live session was NOT pruned, and the mid-reconcile tick was neither lost nor doubled.
        let after = try #require(try app.cache.localSession(id: sid))
        #expect(after.timeListening == 25)                          // 20 + 5, exactly once (not 20, not 45)

        // No double-count across the seam: seal it and reconcile again — the server sees 25 ONCE, then pruned.
        await app.closeCurrentSession()
        await transport.enqueue(status: 200, json: #"{"id":"root","username":"root","mediaProgress":[]}"#)
        await transport.enqueue(status: 200, json: #"{"results":[{"id":"\#(sid)","success":true}]}"#)
        await app.reconcileOnReconnect()
        #expect(await lastLocalAllTimeListening(transport)[sid] == 25)   // posted total is 25, never 45
        #expect(try app.cache.localSession(id: sid) == nil)             // sealed + synced → pruned
    }

    /// ADVERSARIAL CONCURRENCY (the reentrancy guard, RED-verified by dropping it): two rapid
    /// OFFLINE→ONLINE transitions do NOT double-start the reconcile. The first holds `isReconciling`
    /// (parked on `me()`); the second is dropped, so only ONE `me()` round trip is in flight.
    @Test func reconcileNotDoubleStartedOnTwoRapidTransitions() async throws {
        let transport = GatedTransport(gatePath: "api/me")
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 200, json: loginOK)
        await transport.enqueue(status: 200, json: librariesOK)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try seedLocalSession(app, id: "S1", connectionID: cid, itemID: "A", timeListening: 10)

        await transport.enqueue(status: 200, json: #"{"id":"root","username":"root","mediaProgress":[]}"#)
        await transport.enqueue(status: 200, json: #"{"results":[{"id":"S1","success":true}]}"#)

        // First transition: reconcile #1 parks on the me() gate (isReconciling held).
        let first = Task { await app.reconcileOnReconnect() }
        while await transport.requestCount(pathContains: "api/me") == 0 { await Task.yield() }

        // Second transition while #1 is in-flight: dropped by the reentrancy guard.
        let second = Task { await app.reconcileOnReconnect() }
        for _ in 0..<200 { await Task.yield() }
        #expect(await transport.requestCount(pathContains: "api/me") == 1)   // NOT double-started

        await transport.openGate()
        await first.value
        await second.value
        #expect(try app.cache.localSession(id: "S1") == nil)                 // the one reconcile completed + pruned
    }

    /// The NWPathMonitor wiring: an OFFLINE→ONLINE path edge TRIGGERS the reconnect reconcile (and a
    /// redundant satisfied update does NOT). Drives the deterministic seam `handleNetworkPathUpdate`.
    @Test func networkPathOfflineToOnlineEdgeTriggersReconcile() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try seedLocalSession(app, id: "S1", connectionID: cid, itemID: "A", timeListening: 10)
        await transport.enqueue(status: 200, json: #"{"id":"root","username":"root","mediaProgress":[]}"#)
        await transport.enqueue(status: 200, json: #"{"results":[{"id":"S1","success":true}]}"#)

        // Link drops, then returns — the false→true edge fires the reconcile.
        app.handleNetworkPathUpdate(isSatisfied: false)
        #expect(app.isNetworkAvailable == false)
        app.handleNetworkPathUpdate(isSatisfied: true)
        #expect(app.isNetworkAvailable == true)

        var guardCount = 0
        while (try? app.cache.localSession(id: "S1")) ?? nil != nil {
            await Task.yield()
            guardCount += 1
            if guardCount > 5000 { break }
        }
        #expect(try app.cache.localSession(id: "S1") == nil)   // the edge triggered a reconcile that pruned S1
        #expect(app.isOnline == true)

        // A redundant satisfied update (already available) is NOT a new edge → no second reconcile
        // (there are no more queued responses; a second me() would throw — harmless — but the me()
        // count must not climb from another triggered reconcile).
        let meCountBefore = await transport.recorded.filter { ($0.url?.path ?? "").hasSuffix("/api/me") }.count
        app.handleNetworkPathUpdate(isSatisfied: true)
        for _ in 0..<200 { await Task.yield() }
        let meCountAfter = await transport.recorded.filter { ($0.url?.path ?? "").hasSuffix("/api/me") }.count
        #expect(meCountAfter == meCountBefore)
    }

    // MARK: - M2a whole-branch final review fixes

    /// Fix #1 (Important): an OFFLINE tap on a NON-downloaded item is a CLEAN NO-OP — it must NOT
    /// retire the current (offline) playback, and must NOT hit the dead server's `/play`. `client` is
    /// NON-nil offline (valid tokens, server down, link up), so the pre-fix `guard let client` fell
    /// through: `retireCurrentSession()` stopped the current offline book, then `client.startPlayback`
    /// hit the dead host. RED-verify: dropping `if isOffline { return }` makes `nowPlayingItemID` go
    /// nil (retired) AND records a `/play` request → both assertions below fail.
    @Test func offlineTapOnNonDownloadedItemIsCleanNoOp() async throws {
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()                     // nothing queued → the probe fails like a dead host
        let tokenStore = InMemoryTokenStore()
        let app = makeAppWithDownloads(dir: makeTempDir(), downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: tokenStore)
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try seedDownloadedBook(app, connectionID: "C1", itemID: "dl1", downloadsRoot: downloadsRoot,
                               duration: 120, currentTime: 0)
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")

        await app.activateConnection("C1")
        var spins = 0
        while !app.isOffline, spins < 5000 { await Task.yield(); spins += 1 }
        #expect(app.isOffline)
        #expect(app.client != nil)                          // NON-nil offline — isolates the isOffline no-op

        // Current offline playback: the downloaded book plays from LOCAL files even offline.
        await app.startPlayback(itemID: "dl1")
        #expect(app.nowPlayingItemID == "dl1")
        #expect(app.playback.playMethod == LocalPlaybackSession.playMethodLocal)
        let recordedBefore = await transport.recorded.count

        // Tap Play on a NON-downloaded item while offline → must be a clean no-op.
        await app.startPlayback(itemID: "not-downloaded")

        #expect(app.nowPlayingItemID == "dl1")                                          // current playback UNTOUCHED
        #expect(app.playback.playMethod == LocalPlaybackSession.playMethodLocal)        // session not retired
        let playCount = await transport.recorded.filter { ($0.url?.path ?? "").contains("/play") }.count
        #expect(playCount == 0)                                                         // NO /play attempted
        #expect(await transport.recorded.count == recordedBefore)                       // no network at all
    }

    /// Fix #2 (Important): SERVER recovery WITHOUT a link flap. The stored-token probe settling
    /// ONLINE (`isOnline` false→true) must ITSELF trigger the reconnect reconcile — the NWPathMonitor
    /// link edge never fires here (the DEVICE link stayed up; only the SERVER recovered), yet pending
    /// offline sessions must still sync. RED-verify: removing the probe-success `reconcileAfterServer
    /// Recovery` call leaves S1 unpushed/unpruned → the prune + local-all assertions fail.
    @Test func probeSuccessTriggersReconcileWithoutLinkFlap() async throws {
        let transport = MockTransport()
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: tokenStore)
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")
        try seedLocalSession(app, id: "S1", connectionID: "C1", itemID: "A", timeListening: 10)

        // FIFO for: probe /api/authorize, probe /api/libraries, then the recovery reconcile's
        // /api/me (empty) + /api/session/local-all (S1 success). The trigger fires AFTER the probe's
        // own libraries() completes, so nothing races the FIFO.
        await transport.enqueue(status: 200, json: "{}")                                                   // /api/authorize
        await transport.enqueue(status: 200, json: librariesOK)                                            // /api/libraries
        await transport.enqueue(status: 200, json: #"{"id":"root","username":"root","mediaProgress":[]}"#) // /api/me
        await transport.enqueue(status: 200, json: #"{"results":[{"id":"S1","success":true}]}"#)           // local-all

        await app.activateConnection("C1")                  // the link NEVER flaps — only the probe drives this
        var spins = 0
        while ((try? app.cache.localSession(id: "S1")) ?? nil) != nil, spins < 5000 { await Task.yield(); spins += 1 }

        #expect(app.isOnline == true)                                       // probe settled online
        #expect(try app.cache.localSession(id: "S1") == nil)               // recovery reconcile pushed + pruned S1
        let localAll = await transport.recorded.filter { ($0.url?.path ?? "").contains("session/local-all") }.count
        #expect(localAll == 1)                                             // syncLocalSessions called exactly once
    }

    /// Fix #2 (the reentrancy guard, RED-verified by dropping it): the probe-success recovery
    /// reconcile and a concurrent NWPathMonitor link edge do NOT double-run — the `isReconciling`
    /// guard drops the second, so `me()` is hit exactly once even when BOTH signals fire.
    @Test func serverRecoveryAndLinkEdgeReconcileOnlyOnce() async throws {
        let transport = GatedTransport(gatePath: "api/me")
        await transport.enqueue(status: 200, json: statusOK)
        await transport.enqueue(status: 200, json: loginOK)
        await transport.enqueue(status: 200, json: librariesOK)
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try seedLocalSession(app, id: "S1", connectionID: cid, itemID: "A", timeListening: 10)
        await transport.enqueue(status: 200, json: #"{"id":"root","username":"root","mediaProgress":[]}"#)
        await transport.enqueue(status: 200, json: #"{"results":[{"id":"S1","success":true}]}"#)

        // Signal one (stands in for the probe-success recovery): parks on the me() gate.
        let first = Task { await app.reconcileOnReconnect() }
        while await transport.requestCount(pathContains: "api/me") == 0 { await Task.yield() }
        // Signal two via the REAL link-edge seam while #1 is in flight: dropped by isReconciling.
        app.handleNetworkPathUpdate(isSatisfied: false)
        app.handleNetworkPathUpdate(isSatisfied: true)
        for _ in 0..<200 { await Task.yield() }
        #expect(await transport.requestCount(pathContains: "api/me") == 1)   // NOT double-run

        await transport.openGate()
        await first.value
        #expect(try app.cache.localSession(id: "S1") == nil)
    }

    /// Fix #3 (Important): the shared browse fast-path the Series/Authors views route through
    /// (`browseFetch`) SKIPS the network when the server is known-unreachable — it returns `nil` and
    /// records NO request. `client` is NON-nil offline, so this isolates the `isOffline` gate from the
    /// nil-client short-circuit (the exact trap the pre-fix bare-client guard fell into). RED-verify:
    /// dropping `!isOffline` from `browseFetch` runs the closure → a doomed request is recorded → the
    /// no-request assertion fails.
    @Test func browseFetchSkipsNetworkWhenServerKnownUnreachable() async throws {
        let transport = MockTransport()                     // nothing queued → the probe fails like a dead host
        let tokenStore = InMemoryTokenStore()
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: tokenStore)
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try await tokenStore.save(TokenPair(accessToken: "acc", refreshToken: "ref"), for: "C1")
        await app.activateConnection("C1")
        var spins = 0
        while !app.isOffline, spins < 5000 { await Task.yield(); spins += 1 }
        #expect(app.isOffline)
        #expect(app.client != nil)
        let before = await transport.recorded.count

        let series = try await app.browseFetch { try await $0.series(libraryID: "L1", limit: 10) }
        let authors = try await app.browseFetch { try await $0.authors(libraryID: "L1") }
        let author = try await app.browseFetch { try await $0.author(id: "aut1", include: "items") }

        #expect(series == nil)                                   // degraded to offline — no value
        #expect(authors == nil)
        #expect(author == nil)
        #expect(await transport.recorded.count == before)        // NO /series, /authors, /author request issued
    }

    /// Fix #3 (online, no regression): the SAME helper DOES run the fetch and record a request when
    /// the server is reachable — the gate is a genuine no-op online.
    @Test func browseFetchRunsFetchWhenOnline() async throws {
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        await transport.enqueue(status: 200, json: #"{"results":[],"total":0}"#)   // the /series response
        let app = makeApp(dir: makeTempDir(), transport: transport, tokenStore: InMemoryTokenStore())
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        #expect(app.isOffline == false)
        let before = await transport.recorded.count

        _ = try await app.browseFetch { try await $0.series(libraryID: "lib1", limit: 10) }

        let seriesReqs = await transport.recorded.filter { ($0.url?.path ?? "").contains("/series") }.count
        #expect(seriesReqs >= 1)                                 // real fetch happened; online path unregressed
        #expect(await transport.recorded.count > before)
    }

    /// Fix #5 (Minor): a MANUAL delete of the download you're playing FROM LOCAL FILES retires the
    /// session FIRST, so no live `AVPlayer` is left pointed at just-deleted files. RED-verify:
    /// reverting `deleteDownload` to a bare `downloads.delete` leaves `nowPlayingItemID == "dl1"`
    /// while the files vanish → the retire assertion fails.
    @Test func manualDeleteOfCurrentlyPlayingLocalDownloadRetiresPlaybackFirst() async throws {
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: makeTempDir(), downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        let fileURL = try seedDownloadedBook(app, connectionID: "C1", itemID: "dl1", downloadsRoot: downloadsRoot,
                                             duration: 120, currentTime: 0)
        await app.activateConnection("C1")
        await app.startPlayback(itemID: "dl1")
        #expect(app.nowPlayingItemID == "dl1")
        #expect(app.isPlayingFromLocalFiles(itemID: "dl1", episodeID: nil))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        await app.deleteDownload(itemID: "dl1", episodeID: nil)

        #expect(app.nowPlayingItemID == nil)                                          // playback retired first
        #expect(try app.cache.download(connectionID: "C1", itemID: "dl1", episodeID: "") == nil)   // row removed
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))                // files removed
    }

    /// Fix #5 (guard scope): deleting a DIFFERENT (not-currently-playing) download must NOT disturb
    /// the live session — only the item playing from local files is protected.
    @Test func manualDeleteOfADifferentDownloadDoesNotDisturbPlayback() async throws {
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: makeTempDir(), downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try seedDownloadedBook(app, connectionID: "C1", itemID: "dl1", downloadsRoot: downloadsRoot,
                               duration: 120, currentTime: 0)
        let otherURL = try seedDownloadedBook(app, connectionID: "C1", itemID: "dl2", downloadsRoot: downloadsRoot,
                                              duration: 60, currentTime: 0, title: "Other Book")
        await app.activateConnection("C1")
        await app.startPlayback(itemID: "dl1")
        #expect(app.nowPlayingItemID == "dl1")

        await app.deleteDownload(itemID: "dl2", episodeID: nil)

        #expect(app.nowPlayingItemID == "dl1")                                        // live session untouched
        #expect(try app.cache.download(connectionID: "C1", itemID: "dl2", episodeID: "") == nil)   // dl2 removed
        #expect(!FileManager.default.fileExists(atPath: otherURL.path))
    }

    // MARK: - Podcast auto-delete-after-finished (M2a Task 8)

    /// The pure eligibility decision (`AppState.shouldAutoDeleteFinishedEpisode`) against the spec's
    /// exact conservative truth table — no cache/`UserDefaults` dependency, so every flip is asserted
    /// independently. The ONLY eligible case is a WITNESSED false→true transition (`wasFinished ==
    /// false`) on a downloaded episode with the toggle ON. Every other prior state or field is
    /// individually disqualifying — crucially the two that prevent the mass-delete bug: NO prior row
    /// (`wasFinished == nil`, a fresh/rebuilt cache or first full-history sync) and ALREADY-finished
    /// (`wasFinished == true`, a full-history reprocess).
    @Test func autoDeleteDecisionTableMatchesTheConservativeSpec() {
        #expect(AppState.shouldAutoDeleteFinishedEpisode(     // witnessed false→true — the one eligible case
            episodeID: "ep1", wasFinished: false, isFinished: true, isDownloaded: true, toggleOn: true) == true)
        #expect(AppState.shouldAutoDeleteFinishedEpisode(     // NO prior row — not a transition (mass-delete guard)
            episodeID: "ep1", wasFinished: nil, isFinished: true, isDownloaded: true, toggleOn: true) == false)
        #expect(AppState.shouldAutoDeleteFinishedEpisode(     // already finished — reprocess, not a transition
            episodeID: "ep1", wasFinished: true, isFinished: true, isDownloaded: true, toggleOn: true) == false)
        #expect(AppState.shouldAutoDeleteFinishedEpisode(     // a book — never
            episodeID: "", wasFinished: false, isFinished: true, isDownloaded: true, toggleOn: true) == false)
        #expect(AppState.shouldAutoDeleteFinishedEpisode(     // unfinished incoming — never
            episodeID: "ep1", wasFinished: false, isFinished: false, isDownloaded: true, toggleOn: true) == false)
        #expect(AppState.shouldAutoDeleteFinishedEpisode(     // not downloaded — nothing to delete
            episodeID: "ep1", wasFinished: false, isFinished: true, isDownloaded: false, toggleOn: true) == false)
        #expect(AppState.shouldAutoDeleteFinishedEpisode(     // toggle off — never
            episodeID: "ep1", wasFinished: false, isFinished: true, isDownloaded: true, toggleOn: false) == false)
    }

    /// END-TO-END wiring: a downloaded episode's progress reaching `isFinished` via the live socket
    /// path (`apply(.progressUpdated(...))` — one of the "cachedProgress isFinished update" trigger
    /// sites) with the Settings toggle ON actually calls `DownloadCoordinator.delete` — the cache row
    /// AND the on-disk file are both gone afterward, not just a decision made.
    @Test func autoDeleteRemovesDownloadedFinishedEpisodeWhenToggleOn() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(true, forKey: AppState.deleteAfterFinishedKey)

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        let fileURL = try seedDownloadedEpisode(app, connectionID: "C1", itemID: "pod1", episodeID: "ep1",
                                                downloadsRoot: downloadsRoot, duration: 400, currentTime: 90)
        await app.activateConnection("C1")   // no tokens → offline; sets activeConnectionID, no client needed

        await app.apply(.progressUpdated(ProgressUpdate(
            itemID: "pod1", episodeID: "ep1", currentTime: 400, isFinished: true, lastUpdate: 2)))

        #expect(try app.cache.download(connectionID: "C1", itemID: "pod1", episodeID: "ep1") == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(await transport.recorded.isEmpty)   // no network — delete is entirely local
    }

    /// The toggle's OFF (default) half: the identical finished-episode signal leaves the download
    /// untouched.
    @Test func autoDeleteLeavesDownloadUntouchedWhenToggleOff() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(false, forKey: AppState.deleteAfterFinishedKey)   // explicit OFF

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try seedDownloadedEpisode(app, connectionID: "C1", itemID: "pod1", episodeID: "ep1",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 90)
        await app.activateConnection("C1")

        await app.apply(.progressUpdated(ProgressUpdate(
            itemID: "pod1", episodeID: "ep1", currentTime: 400, isFinished: true, lastUpdate: 2)))

        #expect(try app.cache.download(connectionID: "C1", itemID: "pod1", episodeID: "ep1") != nil)
    }

    /// "Never delete a book": the SAME finished signal, toggle ON, for a BOOK (`episodeID` nil →
    /// empty) leaves its download untouched — the spec's conservative guard, not just an incidental
    /// side effect of the episode-only wiring.
    @Test func autoDeleteNeverAppliesToABook() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(true, forKey: AppState.deleteAfterFinishedKey)

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try seedDownloadedBook(app, connectionID: "C1", itemID: "book1",
                               downloadsRoot: downloadsRoot, duration: 300, currentTime: 0)
        await app.activateConnection("C1")

        await app.apply(.progressUpdated(ProgressUpdate(
            itemID: "book1", episodeID: nil, currentTime: 300, isFinished: true, lastUpdate: 2)))

        #expect(try app.cache.download(connectionID: "C1", itemID: "book1") != nil)
    }

    /// "Never delete an unfinished episode": toggle ON, downloaded episode, but `isFinished == false`
    /// — untouched.
    @Test func autoDeleteNeverAppliesToAnUnfinishedEpisode() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(true, forKey: AppState.deleteAfterFinishedKey)

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        try seedDownloadedEpisode(app, connectionID: "C1", itemID: "pod1", episodeID: "ep1",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 90)
        await app.activateConnection("C1")

        await app.apply(.progressUpdated(ProgressUpdate(
            itemID: "pod1", episodeID: "ep1", currentTime: 90, isFinished: false, lastUpdate: 2)))

        #expect(try app.cache.download(connectionID: "C1", itemID: "pod1", episodeID: "ep1") != nil)
    }

    /// CRITICAL regression (the mass-delete bug, `.progressBatch` path): a `user_updated` push carries
    /// the WHOLE user object — the ENTIRE finished-episode history — every time. Re-processing it with
    /// the toggle ON and MULTIPLE already-finished downloaded episodes must delete NOTHING (no
    /// false→true transition is witnessed — every row was ALREADY finished). RED-verified: drop the
    /// `wasFinished == false` gate from `shouldAutoDeleteFinishedEpisode` and BOTH downloads vanish.
    @Test func fullHistoryProgressBatchReprocessDeletesNothingWithoutTransitions() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(true, forKey: AppState.deleteAfterFinishedKey)

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        // Two downloaded episodes, EACH already finished in the cache (prior isFinished == true) —
        // the state a user reaches after finishing them over time with the toggle OFF.
        try seedDownloadedEpisode(app, connectionID: "C1", itemID: "pod1", episodeID: "ep1",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 0)
        try seedDownloadedEpisode(app, connectionID: "C1", itemID: "pod1", episodeID: "ep2",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 0)
        try app.cache.upsertProgress(CachedProgress(connectionID: "C1", itemID: "pod1", episodeID: "ep1",
                                                    currentTime: 400, isFinished: true, lastUpdate: 1))
        try app.cache.upsertProgress(CachedProgress(connectionID: "C1", itemID: "pod1", episodeID: "ep2",
                                                    currentTime: 400, isFinished: true, lastUpdate: 1))
        await app.activateConnection("C1")

        // The user just flipped the toggle ON; a `user_updated` push re-lists the whole finished history.
        await app.apply(.progressBatch([
            ProgressUpdate(itemID: "pod1", episodeID: "ep1", currentTime: 400, isFinished: true, lastUpdate: 2),
            ProgressUpdate(itemID: "pod1", episodeID: "ep2", currentTime: 400, isFinished: true, lastUpdate: 2),
        ]))

        #expect(try app.cache.download(connectionID: "C1", itemID: "pod1", episodeID: "ep1") != nil)
        #expect(try app.cache.download(connectionID: "C1", itemID: "pod1", episodeID: "ep2") != nil)
    }

    /// CRITICAL regression (the mass-delete bug, `refreshProgress()`/`me()` path): `GET /api/me`
    /// returns the FULL mediaProgress history on every Home appear / foreground / pull-to-refresh. The
    /// same "toggle ON + multiple already-finished downloaded episodes" state must survive it — the
    /// history reprocess witnesses no transition, so nothing is deleted.
    @Test func fullHistoryMeReprocessDeletesNothingWithoutTransitions() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(true, forKey: AppState.deleteAfterFinishedKey)

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        try seedDownloadedEpisode(app, connectionID: cid, itemID: "pod1", episodeID: "ep1",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 0)
        try seedDownloadedEpisode(app, connectionID: cid, itemID: "pod1", episodeID: "ep2",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 0)
        try app.cache.upsertProgress(CachedProgress(connectionID: cid, itemID: "pod1", episodeID: "ep1",
                                                    currentTime: 400, isFinished: true, lastUpdate: 1))
        try app.cache.upsertProgress(CachedProgress(connectionID: cid, itemID: "pod1", episodeID: "ep2",
                                                    currentTime: 400, isFinished: true, lastUpdate: 1))
        await transport.enqueue(status: 200, json: #"""
        {"id":"root","username":"root","mediaProgress":[
          {"libraryItemId":"pod1","episodeId":"ep1","currentTime":400,"isFinished":true,"lastUpdate":500},
          {"libraryItemId":"pod1","episodeId":"ep2","currentTime":400,"isFinished":true,"lastUpdate":500}
        ]}
        """#)

        await app.refreshProgress()

        #expect(try app.cache.download(connectionID: cid, itemID: "pod1", episodeID: "ep1") != nil)
        #expect(try app.cache.download(connectionID: cid, itemID: "pod1", episodeID: "ep2") != nil)
    }

    /// The genuine transition still deletes even via the me() path: a prior UNFINISHED cached row →
    /// the me() join reports it finished → false→true transition → deleted (proves the gate isn't
    /// over-broad, i.e. it doesn't block real transitions, only history reprocesses).
    @Test func meJoinDeletesOnGenuineFinishTransition() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(true, forKey: AppState.deleteAfterFinishedKey)

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        await enqueueSuccessfulConnect(transport)
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        await app.connect(serverURL: "http://s:13378", username: "root", password: "pw")
        let cid = try #require(app.activeConnectionID)
        // Prior row is UNFINISHED (in-progress) — the me() join below flips it to finished.
        try seedDownloadedEpisode(app, connectionID: cid, itemID: "pod1", episodeID: "ep1",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 90)
        await transport.enqueue(status: 200, json: #"""
        {"id":"root","username":"root","mediaProgress":[
          {"libraryItemId":"pod1","episodeId":"ep1","currentTime":400,"isFinished":true,"lastUpdate":500}
        ]}
        """#)

        await app.refreshProgress()

        #expect(try app.cache.download(connectionID: cid, itemID: "pod1", episodeID: "ep1") == nil)
    }

    /// IMPORTANT guard: the CURRENTLY-PLAYING episode is never auto-deleted. A cross-device "mark
    /// finished" socket push (a genuine false→true transition, toggle ON, downloaded) for the episode
    /// you're actively streaming must NOT yank its file mid-stream — even though every other condition
    /// for deletion holds.
    @Test func autoDeleteNeverDeletesTheCurrentlyPlayingEpisode() async throws {
        let restoreToggle = snapshotDefault(AppState.deleteAfterFinishedKey)
        defer { restoreToggle() }
        UserDefaults.standard.set(true, forKey: AppState.deleteAfterFinishedKey)

        let dir = makeTempDir()
        let downloadsRoot = makeTempDir()
        let transport = MockTransport()
        let app = makeAppWithDownloads(dir: dir, downloadsRoot: downloadsRoot,
                                       transport: transport, tokenStore: InMemoryTokenStore())
        app.playback.muted = true
        try app.cache.upsertConnection(CachedConnection(id: "C1", address: "http://s:13378", name: "Home",
                                                        username: "root", authMethod: "local", sortIndex: 0))
        // Prior UNFINISHED progress (currentTime 90) so the push below is a real false→true transition.
        try seedDownloadedEpisode(app, connectionID: "C1", itemID: "pod1", episodeID: "ep1",
                                  downloadsRoot: downloadsRoot, duration: 400, currentTime: 90)
        await app.activateConnection("C1")
        await app.startPlayback(itemID: "pod1", episodeId: "ep1", podcastTitle: "Pod")
        #expect(app.nowPlayingEpisodeID == "ep1")   // it IS the episode now playing

        await app.apply(.progressUpdated(ProgressUpdate(
            itemID: "pod1", episodeID: "ep1", currentTime: 400, isFinished: true, lastUpdate: 2)))

        // Not deleted mid-stream, despite the real transition + downloaded + toggle on.
        #expect(try app.cache.download(connectionID: "C1", itemID: "pod1", episodeID: "ep1") != nil)
    }
}
