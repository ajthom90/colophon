# Colophon M1a — Foundation & Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the M0 walking skeleton into a correct, cache-backed, live-updating streaming client: session lifecycle done right, a unit-testable player core, a GRDB library cache the UI observes, cover caching, and real-time socket updates.

**Architecture:** Three moves. (1) Put a `PlayerBackend` protocol seam under `PlaybackController` so the player's logic (timeline, listened-accounting, sync cadence) is unit-tested against a fake, and give sessions a real lifecycle owner (`PlaybackSessionHandle`: sync → 404-recovery → close). (2) Introduce the `LibraryCache` GRDB package; views observe the cache, the network writes into it — the M1-and-beyond data flow. (3) Add `ABSRealtime` (Socket.IO) so server-side changes stream into the cache live.

**Tech Stack:** Swift 6.2, GRDB.swift 7 (MIT), socket.io-client-swift 16.1.1 (adopt-verdict config from the M0 spike), Swift Testing, existing XcodeGen/Docker infra.

## Global Constraints

- All M0 global constraints still bind (deployment targets iOS/macOS 26.0; Xcode 26.6; strict concurrency; server ≥ 2.26.0; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`) — EXCEPT the bundle ID, which is now **`com.andrewthom.colophon`** (changed 2026-07-06) with `DEVELOPMENT_TEAM: LL334G7KP2` and `CODE_SIGN_STYLE: Automatic` in project.yml. Never reintroduce the old `com.ajthom90.*` identifiers.
- New dependencies, exactly: `https://github.com/groue/GRDB.swift` from `"7.0.0"` (LibraryCache package only) and `https://github.com/socketio/socket.io-client-swift` from `"16.1.0"` (ABSKit package's new `ABSRealtime` target only — the core `ABSKit` target stays dependency-free).
- Socket config per the M0 spike verdict: `.forceWebsockets(true), .version(.three), .compress` plus tuned `.reconnectWait(2), .reconnectWaitMax(10)`.
- Session semantics: `timeListened` = delta since last **successful** sync; accrual during an in-flight sync must survive (`didSync` consumes only the emitted amount); every started session is eventually closed or flushed (background/termination included); sync 404 → `POST /api/session/local` upsert fallback (server restarted; sessions are in-memory).
- Tick atomicity invariant (M0 fix c27540a) must survive the backend seam: the (track index, offset) pair is always read off the SAME player item.
- Tokens stay device-local; Keychain items now also set `kSecUseDataProtectionKeychain = true`. Connection identity = UUID string (never the server URL); one-time migration from M0's URL-string keychain keys.
- CarPlay: deferred entirely (user decision 2026-07-06) — nothing here may reference it.
- DEBUG-only test hooks (`COLOPHON_AUTO_*`) stay `#if DEBUG`; headless E2E runs MUST terminate the launched app in cleanup (M0 lesson: simulator audio plays on the host's speakers), and the new `COLOPHON_AUTO_MUTE=1` env (Task 4) must be set on every headless run.
- Contract tests remain env-gated on `ABS_CONTRACT_URL`; dev server via `make server-up && make seed` (root / colophon-dev @ localhost:13378).

## File Structure (end state of M1a)

```
devserver/seed.sh                     + cover fixture download (before scan)
devserver/docker-compose.yml          + restart: unless-stopped
Packages/ABSKit/Sources/ABSKit/
  Transport.swift                     + LocalizedError, ABSError.serverTooOld
  ServerVersion.swift                 NEW — parse/compare "2.35.1"-style versions
  AuthManager.swift                   + tokenUpdates AsyncStream
  TokenStore.swift                    + kSecUseDataProtectionKeychain
  ABSClient.swift                     startPlayback → PlaybackSessionEnvelope; + postLocalSession
  PlaybackSessionHandle.swift         NEW — sync/404-recovery/close owner (actor)
Packages/ABSKit/Sources/ABSRealtime/  NEW target (product ABSRealtime)
  ServerEvent.swift                   event model + payload decoding
  SocketService.swift                 connect/auth/re-auth/reconnect → AsyncStream<ServerEvent>
Packages/LibraryCache/                NEW package
  Sources/LibraryCache/Schema.swift          migrations (v1)
  Sources/LibraryCache/Records.swift         CachedConnection/CachedLibrary/CachedItem/CachedProgress
  Sources/LibraryCache/LibraryCacheStore.swift  pool, upserts, observations, FTS search
  Sources/LibraryCache/CoverStore.swift      ts-keyed disk cover cache (actor)
Packages/PlayerEngine/Sources/PlayerEngine/
  PlayerBackend.swift                 NEW — protocol + AVQueuePlayerBackend
  PlayerEngine.swift                  PlaybackController refactor: logic only, injected backend+clock
  SessionSyncController.swift         consume-semantics didSync
App/
  AppState.swift                      → ConnectionManager + session lifecycle + socket wiring
  Views/LibrariesView.swift           observes cache
  Views/LibraryItemsView.swift        observes cache; retry UX; CachedCoverView
  Views/CachedCoverView.swift         NEW
project.yml                           + LibraryCache package, version-var Info.plist keys
```

**Cross-task interface contracts** (task Interfaces blocks repeat the parts they touch):

```swift
// ABSKit
public struct ServerVersion: Comparable, Sendable { public let major, minor, patch: Int; public init?(_ string: String) }
extension ABSError { case serverTooOld(found: String) }               // + LocalizedError on ABSError & TokenStoreError

public struct PlaybackSessionEnvelope: Sendable {
    public let session: PlaybackSession
    public let rawData: Data                                          // exact server JSON, for local-session upserts
}
// ABSClient (changed/new):
public func startPlayback(itemID: String, deviceInfo: DeviceInfo) async throws -> PlaybackSessionEnvelope
public func postLocalSession(rawData: Data, currentTime: Double, totalListened: Double) async throws
// AuthManager (new):
public var tokenUpdates: AsyncStream<String> { get }                  // yields after every successful login/refresh

public actor PlaybackSessionHandle {
    public init(client: ABSClient, envelope: PlaybackSessionEnvelope)
    public var sessionID: String { get }
    public func sync(currentTime: Double, timeListened: Double) async -> Bool   // true = server acknowledged (incl. 404→local fallback)
    public func close(currentTime: Double, timeListened: Double) async
}

// ABSRealtime
public struct ProgressUpdate: Sendable, Equatable {
    public let itemID: String; public let episodeID: String?
    public let currentTime: Double; public let isFinished: Bool; public let lastUpdate: Int
}
public enum ServerEvent: Sendable, Equatable {
    case progressUpdated(ProgressUpdate)
    case itemChanged(id: String), itemsChanged(ids: [String]), itemRemoved(id: String)
}
@MainActor public final class SocketService {
    public init(serverURL: URL, tokenProvider: @escaping @Sendable () async -> String?)
    public func events() -> AsyncStream<ServerEvent>                  // starts the connection on first call
    public func reauthenticate() async                                 // call when the access token rotates
    public func stop()
}

// LibraryCache
public struct LibraryCacheStore: Sendable {
    public init(databaseURL: URL) throws                              // runs migrations
    public func upsertConnection(_ c: CachedConnection) throws
    public func connections() throws -> [CachedConnection]
    public func upsertLibraries(_ libs: [CachedLibrary], connectionID: String) throws
    public func upsertItemsPage(_ items: [CachedItem], connectionID: String, libraryID: String) throws
    public func upsertProgress(_ p: CachedProgress) throws
    public func observeLibraries(connectionID: String) -> AsyncValueObservation<[CachedLibrary]>
    public func observeItems(connectionID: String, libraryID: String) -> AsyncValueObservation<[CachedItem]>
    public func searchItems(connectionID: String, query: String) throws -> [CachedItem]
}
public actor CoverStore {
    public init(directory: URL)
    public func coverData(connectionID: String, itemID: String, updatedAt: Int?,
                          fetch: @Sendable () async throws -> Data) async throws -> Data
}

// PlayerEngine
@MainActor public protocol PlayerBackend: AnyObject {
    var onTick: (() -> Void)? { get set }
    var onItemFinished: ((_ finishedIndex: Int, _ wasLast: Bool) -> Void)? { get set }
    var currentPosition: (index: Int, offset: TimeInterval)? { get }  // MUST be read off one item (atomic pair)
    var playbackRate: Float { get set }
    func setQueue(urls: [URL], startIndex: Int, startOffset: TimeInterval)
    func play(); func pause()
    func seek(toIndex: Int, offset: TimeInterval)
    func teardown()
}
// PlaybackController (changed):
public init(backend: PlayerBackend, now: @escaping @Sendable () -> Date = Date.init)
public func load(session: PlaybackSession, trackURLs: [URL])          // urls parallel to sorted timeline tracks
// SessionSyncController (changed):
public mutating func didSync()                                        // now consumes ONLY the emitted amount
```

---

### Task 1: Dev-infra — cover fixture, restart policy, cover contract test → 200

**Files:**
- Modify: `devserver/seed.sh` (add cover download before the scan step)
- Modify: `devserver/docker-compose.yml` (restart policy)
- Modify: `Packages/ABSKit/Tests/ABSKitTests/ContractTests.swift` (cover test upgrades to 200 + bytes)

**Interfaces:** none new. Produces: every fresh seed yields an item WITH cover art, so cover-pipeline tests (Task 8) and the upgraded contract test have a real image.

- [ ] **Step 1: Add the cover fixture to `devserver/seed.sh`** — insert directly after the book download block (after the `mv`/`trap` section, before the login step):

```bash
COVER="$BOOK_DIR/cover.jpg"
if [ ! -f "$COVER" ]; then
  echo "→ downloading cover art"
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
    "https://archive.org/services/img/art_of_war_librivox" -o "$COVER" \
    || echo "⚠ cover download failed — continuing without cover"
  [ -s "$COVER" ] || rm -f "$COVER"
fi
```

- [ ] **Step 2: Add restart policy** — in `devserver/docker-compose.yml` under the `audiobookshelf:` service add `restart: unless-stopped` (same indent level as `image:`).

- [ ] **Step 3: Upgrade the cover contract test** — in `ContractTests.swift`, replace the body of `coverEndpointIsUnauthenticated` with:

```swift
@Test func coverEndpointIsUnauthenticatedAndServesImage() async throws {
    let client = try await loggedInClient()
    let libs = try await client.libraries()
    let page = try await client.items(libraryID: libs[0].id, limit: 1, page: 0)
    let url = client.coverURL(itemID: page.results[0].id, width: 200, updatedAt: page.results[0].updatedAt)
    let unauthed = try await transport.send(URLRequest(url: url))   // no Authorization header
    #expect(unauthed.statusCode == 200, "seed must provide cover.jpg — re-run make seed after wiping devserver/data")
    #expect(unauthed.data.count > 1_000)                            // a real image, not an error body
}
```

(Keep the test name change; delete the old authed/unauthed comparison — 200 without auth is now the stronger assertion.)

- [ ] **Step 4: Verify against a factory-fresh server**

Run: `make server-down && rm -rf devserver/data && make server-up && make seed && cd Packages/ABSKit && ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests`
Expected: all contract tests PASS, including the new 200 cover assertion. (The scan needs the cover present before it runs — the seed script order guarantees that.)

- [ ] **Step 5: Commit**

```bash
git add devserver Packages/ABSKit/Tests/ABSKitTests/ContractTests.swift
git commit -m "feat(devserver): seed cover art; cover contract test asserts real image"
```

---

### Task 2: SessionSyncController consume-semantics

**Files:**
- Modify: `Packages/PlayerEngine/Sources/PlayerEngine/SessionSyncController.swift`
- Modify: `Packages/PlayerEngine/Tests/PlayerEngineTests/SessionSyncControllerTests.swift` (add tests; existing tests must pass unchanged)

**Interfaces:**
- Produces: `didSync()` subtracts only the amount carried by the last emitted payload (`pendingEmission`), so seconds accrued while a sync round-trip was in flight are no longer wiped. Signatures unchanged.

- [ ] **Step 1: Write the failing test** — append to the existing suite:

```swift
@Test func accrualDuringInFlightSyncSurvivesDidSync() {
    var sut = SessionSyncController(interval: 15)
    // Emission captures 15s; while that POST is in flight, 4 more seconds accrue.
    let payload = sut.noteProgress(currentTime: 15, listenedDelta: 15, now: t0.addingTimeInterval(15))
    #expect(payload?.timeListened == 15)
    _ = sut.noteProgress(currentTime: 19, listenedDelta: 4, now: t0.addingTimeInterval(19))
    sut.didSync()   // server acked the 15s payload — the 4s must survive
    #expect(sut.flush(currentTime: 19) == SyncPayload(currentTime: 19, timeListened: 4))
}

@Test func flushThenDidSyncConsumesOnlyFlushedAmount() {
    var sut = SessionSyncController(interval: 15)
    _ = sut.noteProgress(currentTime: 5, listenedDelta: 5, now: t0.addingTimeInterval(5))
    let flushed = sut.flush(currentTime: 5)
    #expect(flushed?.timeListened == 5)
    _ = sut.noteProgress(currentTime: 7, listenedDelta: 2, now: t0.addingTimeInterval(7))
    sut.didSync()
    #expect(sut.flush(currentTime: 7) == SyncPayload(currentTime: 7, timeListened: 2))
}
```

- [ ] **Step 2: Run to verify failure** — `cd Packages/PlayerEngine && swift test --filter SessionSyncControllerTests` → the two new tests FAIL (didSync currently zeroes everything).

- [ ] **Step 3: Implement** — in `SessionSyncController.swift`: add `private var pendingEmission: Double = 0`; in `noteProgress`, when a payload is emitted set `pendingEmission = accumulatedListened` just before returning it; in `flush`, set `pendingEmission = accumulatedListened` before returning the payload; replace `didSync` with:

```swift
/// Consume ONLY the amount carried by the last emitted/flushed payload —
/// seconds accrued while that sync was in flight stay accumulated.
public mutating func didSync() {
    accumulatedListened = max(0, accumulatedListened - pendingEmission)
    pendingEmission = 0
}
```

- [ ] **Step 4: Run all SessionSyncController tests** — all 8 (6 old + 2 new) PASS. Old tests must not be modified.

- [ ] **Step 5: Commit** — `git add Packages/PlayerEngine && git commit -m "fix(PlayerEngine): didSync consumes only the emitted amount"`

---

### Task 3: Typed errors — LocalizedError + ServerVersion gate

**Files:**
- Create: `Packages/ABSKit/Sources/ABSKit/ServerVersion.swift`
- Modify: `Packages/ABSKit/Sources/ABSKit/Transport.swift` (add `.serverTooOld`, LocalizedError), `Packages/ABSKit/Sources/ABSKit/TokenStore.swift` (LocalizedError)
- Create: `Packages/ABSKit/Tests/ABSKitTests/ServerVersionTests.swift`
- Modify: `App/AppState.swift` (gate in `connect`)

**Interfaces:**
- Produces: `ServerVersion(_:) -> ServerVersion?` Comparable; `ABSError.serverTooOld(found: String)`; `ABSKit.minimumServerVersion = ServerVersion("2.26.0")!`; human-readable `errorDescription` for every ABSError/TokenStoreError case. AppState.connect throws `.serverTooOld` before attempting login.

- [ ] **Step 1: Write failing tests** — `ServerVersionTests.swift`:

```swift
import Testing
@testable import ABSKit

@Suite struct ServerVersionTests {
    @Test func parsesAndCompares() {
        #expect(ServerVersion("2.26.0")! < ServerVersion("2.35.1")!)
        #expect(ServerVersion("2.35.1")! < ServerVersion("3.0.0")!)
        #expect(!(ServerVersion("2.26.0")! < ServerVersion("2.26.0")!))
        #expect(ServerVersion("2.9.0")! < ServerVersion("2.26.0")!)   // numeric, not lexicographic
        #expect(ServerVersion("v2.26.0") == nil)
        #expect(ServerVersion("2.26") == nil)
        #expect(ServerVersion("") == nil)
    }

    @Test func gateConstant() {
        #expect(ABSKit.minimumServerVersion == ServerVersion("2.26.0")!)
    }

    @Test func errorsAreHumanReadable() {
        #expect(ABSError.serverTooOld(found: "2.20.0").errorDescription?.contains("2.26.0") == true)
        #expect(ABSError.http(status: 401).errorDescription?.contains("401") == true)
        #expect(ABSError.notAuthenticated.errorDescription?.isEmpty == false)
        #expect(ABSError.reauthRequired.errorDescription?.isEmpty == false)
        #expect(ABSError.invalidResponse.errorDescription?.isEmpty == false)
        #expect(TokenStoreError.keychainFailure(-25300).errorDescription?.contains("-25300") == true)
    }
}
```

- [ ] **Step 2: Run to verify failure** (`swift test --filter ServerVersionTests` → FAIL, types missing).

- [ ] **Step 3: Implement.** `ServerVersion.swift`:

```swift
import Foundation

public struct ServerVersion: Comparable, Sendable, Equatable {
    public let major: Int, minor: Int, patch: Int

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }

    public static func < (l: ServerVersion, r: ServerVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

public enum ABSKit {
    /// First server release with the JWT access/refresh flow — the spec's support floor.
    public static let minimumServerVersion = ServerVersion("2.26.0")!
}
```

In `Transport.swift`: add `case serverTooOld(found: String)` to `ABSError` and:

```swift
extension ABSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status): "The server returned an error (HTTP \(status))."
        case .notAuthenticated: "You're not signed in to this server."
        case .reauthRequired: "Your session expired. Please sign in again."
        case .invalidResponse: "The server sent an unexpected response."
        case .serverTooOld(let found):
            "This server runs Audiobookshelf \(found). Colophon requires 2.26.0 or newer."
        }
    }
}
```

(Note: `ABSKit.swift` currently declares `enum ABSKitInfo` — leave it; the new `ABSKit` namespace enum lives in ServerVersion.swift. If a name collision arises with the module name, rename the constant holder to `ABSPolicy` and update the test — record the deviation.)

In `TokenStore.swift`:

```swift
extension TokenStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status): "Couldn't store credentials securely (Keychain error \(status))."
        case .encodingFailure: "Couldn't encode credentials for storage."
        }
    }
}
```

In `App/AppState.swift` `connect(...)`, after the `status` fetch and `isInit` check, insert:

```swift
guard let versionString = status.serverVersion,
      let version = ServerVersion(versionString),
      !(version < ABSKit.minimumServerVersion) else {
    throw ABSError.serverTooOld(found: status.serverVersion ?? "unknown")
}
```

and change `errorMessage` assignment in the generic catch to prefer `(error as? LocalizedError)?.errorDescription ?? error.localizedDescription`.

- [ ] **Step 4: Run tests + builds** — `swift test` in ABSKit (all green incl. 3 new), `make build-ios build-mac`.

- [ ] **Step 5: Commit** — `git add Packages/ABSKit App/AppState.swift && git commit -m "feat(ABSKit): server version gate and human-readable errors"`

---

### Task 4: PlayerBackend seam + PlaybackController unit tests

The core correctness task: extract AVFoundation behind a protocol so the controller's logic gets real unit tests. The AV wiring (including the atomic-pair fix and item-identity map) moves into `AVQueuePlayerBackend` unchanged in behavior.

**Files:**
- Create: `Packages/PlayerEngine/Sources/PlayerEngine/PlayerBackend.swift`
- Modify: `Packages/PlayerEngine/Sources/PlayerEngine/PlayerEngine.swift` (PlaybackController refactor)
- Create: `Packages/PlayerEngine/Tests/PlayerEngineTests/FakePlayerBackend.swift`, `PlaybackControllerTests.swift`
- Modify: `App/AppState.swift` (construct backend + pass trackURLs; add `COLOPHON_AUTO_MUTE` DEBUG env → `playback.muted = true`)

**Interfaces:**
- Produces: `PlayerBackend` protocol + `AVQueuePlayerBackend` (contract block above); `PlaybackController.init(backend:now:)`, `load(session:trackURLs:)`, new `public var muted: Bool` (sets backend volume; AVQueuePlayerBackend adds `var volume: Float` — add it to the protocol as `var volume: Float { get set }`). Everything else on PlaybackController keeps its M0 signature (`play/pause/togglePlayPause/skip/seek(toGlobal:)/setRate/unload`, observables, `onSyncDue`).
- Consumes: `BookTimeline`, `SessionSyncController` (Task 2 semantics), `NowPlayingUpdater` (unchanged).

- [ ] **Step 1: Write the failing tests.** `FakePlayerBackend.swift` (test target):

```swift
import Foundation
@testable import PlayerEngine

@MainActor
final class FakePlayerBackend: PlayerBackend {
    var onTick: (() -> Void)?
    var onItemFinished: ((Int, Bool) -> Void)?
    var currentPosition: (index: Int, offset: TimeInterval)?
    var playbackRate: Float = 1.0
    var volume: Float = 1.0
    private(set) var queue: [URL] = []
    private(set) var playing = false
    private(set) var seeks: [(index: Int, offset: TimeInterval)] = []

    func setQueue(urls: [URL], startIndex: Int, startOffset: TimeInterval) {
        queue = urls
        currentPosition = (startIndex, startOffset)
    }
    func play() { playing = true }
    func pause() { playing = false }
    func seek(toIndex index: Int, offset: TimeInterval) {
        seeks.append((index, offset))
        currentPosition = (index, offset)
    }
    func teardown() { queue = []; currentPosition = nil; playing = false }

    /// Advance playback by `seconds` of TIMELINE time within the current track, then tick.
    func advance(by seconds: TimeInterval) {
        if let pos = currentPosition { currentPosition = (pos.index, pos.offset + seconds) }
        onTick?()
    }
    func moveTo(index: Int, offset: TimeInterval, thenTick: Bool = true) {
        currentPosition = (index, offset)
        if thenTick { onTick?() }
    }
}
```

`PlaybackControllerTests.swift`:

```swift
import Foundation
import Testing
import ABSKit
@testable import PlayerEngine

@MainActor
private func makeSession() -> PlaybackSession {
    // Tracks: [0,10), [10,25), [25,30) — same shape as BookTimelineTests.
    let json = """
    {"id":"ses_t","libraryItemId":"li_t","displayTitle":"T","displayAuthor":"A",
     "duration":30,"startTime":0,"currentTime":0,"playMethod":0,"chapters":[],
     "audioTracks":[{"index":1,"startOffset":0,"duration":10},
                    {"index":2,"startOffset":10,"duration":15},
                    {"index":3,"startOffset":25,"duration":5}]}
    """
    return try! JSONDecoder().decode(PlaybackSession.self, from: Data(json.utf8))
}

@MainActor
private func makeSUT(startAt: TimeInterval = 0) -> (PlaybackController, FakePlayerBackend, ClockBox) {
    let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
    let backend = FakePlayerBackend()
    let controller = PlaybackController(backend: backend, now: { clock.now })
    var session = makeSession()
    controller.load(session: session, trackURLs: [
        URL(string: "https://t/1")!, URL(string: "https://t/2")!, URL(string: "https://t/3")!,
    ])
    if startAt > 0 { controller.seek(toGlobal: startAt) }
    controller.play()
    return (controller, backend, clock)
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

@MainActor @Suite struct PlaybackControllerTests {
    @Test func boundaryAdvanceIsContinuous() {
        let (controller, backend, clock) = makeSUT()
        clock.advance(9.5); backend.moveTo(index: 0, offset: 9.5)
        #expect(abs(controller.globalTime - 9.5) < 0.001)
        clock.advance(0.8); backend.moveTo(index: 1, offset: 0.3)   // crossed the 10s boundary
        #expect(abs(controller.globalTime - 10.3) < 0.001)
    }

    @Test func seekDoesNotCountAsListening() async {
        let (controller, backend, clock) = makeSUT()
        var payloads: [SyncPayload] = []
        controller.onSyncDue = { payloads.append($0); return true }
        clock.advance(5); backend.advance(by: 5)
        controller.seek(toGlobal: 28)                               // jump near the end
        #expect(backend.seeks.last!.index == 2)
        #expect(abs(backend.seeks.last!.offset - 3) < 0.001)
        clock.advance(11); backend.advance(by: 1)                   // 15s wall since start → due
        // 5s + 1s of real listening; the 23s jump must not be counted.
        #expect(payloads.count == 1)
        #expect(abs(payloads[0].timeListened - 6) < 0.001)
        #expect(abs(payloads[0].currentTime - 29) < 0.001)
    }

    @Test func fastRateCountsWallClockListening() {
        let (controller, backend, clock) = makeSUT()
        controller.setRate(2.0)
        var payloads: [SyncPayload] = []
        controller.onSyncDue = { payloads.append($0); return true }
        // 2× rate: 16s of timeline in 8s of wall time — but sync cadence needs 15s
        // of LISTENED time before the first emission (listened = timeline/rate = 8s). Not due yet.
        clock.advance(8); backend.advance(by: 16)
        #expect(payloads.isEmpty)
        clock.advance(7); backend.moveTo(index: 1, offset: 20)      // total listened 15s
        #expect(payloads.count == 1)
        #expect(abs(payloads[0].timeListened - 15) < 0.01)
    }

    @Test func bookEndPausesAtTotalDuration() {
        let (controller, backend, _) = makeSUT()
        backend.moveTo(index: 2, offset: 4.9)
        backend.onItemFinished?(2, true)
        #expect(controller.isPlaying == false)
        #expect(controller.globalTime == controller.totalDuration)
    }

    @Test func staleFinishOfNonLastItemDoesNotPause() {
        let (controller, backend, _) = makeSUT()
        backend.onItemFinished?(0, false)
        #expect(controller.isPlaying == true)
    }

    @Test func syncsAreSerialized() async {
        let (controller, backend, clock) = makeSUT()
        var inFlight = 0, maxInFlight = 0, calls = 0
        controller.onSyncDue = { _ in
            inFlight += 1; calls += 1; maxInFlight = max(maxInFlight, inFlight)
            try? await Task.sleep(nanoseconds: 50_000_000)          // slow server
            inFlight -= 1
            return true
        }
        clock.advance(15); backend.advance(by: 15)                  // due → spawns sync task
        clock.advance(15); backend.advance(by: 1)                   // due again while first in flight
        try? await Task.sleep(nanoseconds: 200_000_000)             // let tasks drain
        #expect(maxInFlight == 1)
        #expect(calls >= 1)
    }

    @Test func mutedSetsBackendVolume() {
        let (controller, backend, _) = makeSUT()
        controller.muted = true
        #expect(backend.volume == 0)
        controller.muted = false
        #expect(backend.volume == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd Packages/PlayerEngine && swift test --filter PlaybackControllerTests` → FAIL (no `PlayerBackend`, no new initializer).

- [ ] **Step 3: Implement `PlayerBackend.swift`** — the protocol (contract block, plus `var volume: Float { get set }`) and `AVQueuePlayerBackend`, migrating the AV code out of the current PlaybackController **without behavior change**:

```swift
import Foundation
import AVFoundation

@MainActor
public protocol PlayerBackend: AnyObject {
    var onTick: (() -> Void)? { get set }
    var onItemFinished: ((_ finishedIndex: Int, _ wasLast: Bool) -> Void)? { get set }
    /// Index + offset read off the SAME item — the atomic pair (M0 fix c27540a).
    var currentPosition: (index: Int, offset: TimeInterval)? { get }
    var playbackRate: Float { get set }
    var volume: Float { get set }
    func setQueue(urls: [URL], startIndex: Int, startOffset: TimeInterval)
    func play(); func pause()
    func seek(toIndex index: Int, offset: TimeInterval)
    func teardown()
}

@MainActor
public final class AVQueuePlayerBackend: PlayerBackend {
    public var onTick: (() -> Void)?
    public var onItemFinished: ((Int, Bool) -> Void)?
    public var playbackRate: Float = 1.0 {
        didSet { player?.defaultRate = playbackRate; if isPlaying { player?.rate = playbackRate } }
    }
    public var volume: Float = 1.0 { didSet { player?.volume = volume } }

    private var player: AVQueuePlayer?
    private var urls: [URL] = []
    private var items: [AVPlayerItem] = []
    private var itemIndexByID: [ObjectIdentifier: Int] = [:]
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var isPlaying = false

    public init() {}

    public var currentPosition: (index: Int, offset: TimeInterval)? {
        guard let current = player?.currentItem,
              let index = itemIndexByID[ObjectIdentifier(current)] else { return nil }
        let offset = current.currentTime().seconds
        guard offset.isFinite else { return nil }
        return (index, offset)
    }

    public func setQueue(urls: [URL], startIndex: Int, startOffset: TimeInterval) {
        teardown()
        self.urls = urls
        items = urls.map { url in
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .spectral
            return item
        }
        rebuildIndex()
        let queue = AVQueuePlayer(items: Array(items[startIndex...]))
        queue.defaultRate = playbackRate
        queue.volume = volume
        player = queue
        queue.seek(to: CMTime(seconds: startOffset, preferredTimescale: 1000),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        installObservers(queue)
    }

    public func play() { isPlaying = true; player?.play(); player?.rate = playbackRate }
    public func pause() { isPlaying = false; player?.pause() }

    public func seek(toIndex index: Int, offset: TimeInterval) {
        guard let player else { return }
        if currentPosition?.index != index {
            player.removeAllItems()
            for original in items[index...] {
                let usable = original.currentTime() == .zero && player.canInsert(original, after: nil)
                    ? original
                    : AVPlayerItem(asset: original.asset)
                usable.audioTimePitchAlgorithm = .spectral
                if usable !== original, let i = items.firstIndex(where: { $0 === original }) {
                    items[i] = usable
                }
                player.insert(usable, after: nil)
            }
            rebuildIndex()
            if isPlaying { player.play(); player.rate = playbackRate }
        }
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func teardown() {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
        player?.pause(); player = nil
        items = []; itemIndexByID = [:]; isPlaying = false
    }

    private func rebuildIndex() {
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { (ObjectIdentifier($1), $0) })
    }

    private func installObservers(_ queue: AVQueuePlayer) {
        timeObserver = queue.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let finished = note.object as? AVPlayerItem,
                      let index = self.itemIndexByID[ObjectIdentifier(finished)] else { return }
                self.onItemFinished?(index, index == self.items.count - 1)
            }
        }
    }
}
```

- [ ] **Step 4: Refactor `PlaybackController`** in `PlayerEngine.swift` to pure logic over the backend. Keep the observable surface and `onSyncDue` exactly as in M0; the body becomes:

```swift
import Foundation
import ABSKit
#if canImport(AVFAudio)
import AVFAudio
#endif

@MainActor
@Observable
public final class PlaybackController {
    public private(set) var isPlaying = false
    public private(set) var globalTime: TimeInterval = 0
    public private(set) var totalDuration: TimeInterval = 0
    public private(set) var title = ""
    public private(set) var author = ""
    public var rate: Float = 1.0 { didSet { backend.playbackRate = rate } }
    public var muted = false { didSet { backend.volume = muted ? 0 : 1 } }
    public var onSyncDue: ((SyncPayload) async -> Bool)?

    private let backend: PlayerBackend
    private let now: @Sendable () -> Date
    private var timeline = BookTimeline(tracks: [])
    private var sync = SessionSyncController()
    private var lastTickGlobalTime: TimeInterval = 0
    private var syncInFlight = false
    private let nowPlaying = NowPlayingUpdater()

    public init(backend: PlayerBackend, now: @escaping @Sendable () -> Date = Date.init) {
        self.backend = backend
        self.now = now
        backend.onTick = { [weak self] in self?.tick() }
        backend.onItemFinished = { [weak self] index, wasLast in
            guard let self, wasLast else { return }
            self.globalTime = self.totalDuration
            self.pause()
        }
    }

    public func load(session: PlaybackSession, trackURLs: [URL]) {
        timeline = BookTimeline(tracks: session.audioTracks)
        totalDuration = timeline.totalDuration
        title = session.displayTitle ?? "Untitled"
        author = session.displayAuthor ?? ""
        sync = SessionSyncController()
        syncInFlight = false
        let start = timeline.position(at: session.startTime)
        backend.setQueue(urls: trackURLs, startIndex: start.trackIndex, startOffset: start.offset)
        globalTime = session.startTime
        lastTickGlobalTime = session.startTime
        nowPlaying.configure(controller: self)
        configureAudioSession()
    }

    public func play() { backend.play(); isPlaying = true; nowPlaying.update(controller: self) }

    public func pause() {
        backend.pause(); isPlaying = false
        nowPlaying.update(controller: self)
        Task { await flushSync() }
    }

    public func togglePlayPause() { isPlaying ? pause() : play() }
    public func skip(_ seconds: Double) { seek(toGlobal: globalTime + seconds) }
    public func setRate(_ newRate: Float) { rate = newRate }

    public func seek(toGlobal target: TimeInterval) {
        let position = timeline.position(at: target)
        backend.seek(toIndex: position.trackIndex, offset: position.offset)
        globalTime = timeline.globalTime(trackIndex: position.trackIndex, offset: position.offset)
        lastTickGlobalTime = globalTime
        nowPlaying.update(controller: self)
    }

    public func unload() { backend.teardown(); isPlaying = false }

    private func tick() {
        guard isPlaying, let position = backend.currentPosition else { return }
        globalTime = timeline.globalTime(trackIndex: position.index, offset: position.offset)
        let delta = max(0, globalTime - lastTickGlobalTime)
        lastTickGlobalTime = globalTime
        let listened = Double(delta) / Double(max(rate, 0.1))
        if let payload = sync.noteProgress(currentTime: globalTime, listenedDelta: listened, now: now()),
           let onSyncDue, !syncInFlight {
            syncInFlight = true
            Task {
                if await onSyncDue(payload) { self.sync.didSync() }
                self.syncInFlight = false
            }
        }
        nowPlaying.updateElapsed(controller: self)
    }

    private func flushSync() async {
        guard !syncInFlight, let payload = sync.flush(currentTime: globalTime), let onSyncDue else { return }
        syncInFlight = true
        if await onSyncDue(payload) { sync.didSync() }
        syncInFlight = false
    }

    private func configureAudioSession() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
```

- [ ] **Step 5: Update `App/AppState.swift`** — construct `PlaybackController(backend: AVQueuePlayerBackend())`; in `startPlayback`, build `trackURLs` from the sorted timeline order:

```swift
let timelineTracks = envelope.session.audioTracks.sorted { $0.startOffset < $1.startOffset }
let urls = timelineTracks.map { client.publicTrackURL(sessionID: envelope.session.id, trackIndex: $0.index) }
playback.load(session: envelope.session, trackURLs: urls)
```

(`envelope` arrives in Task 5 — until that task lands, keep `session` naming; this task only changes construction + `load` call shape + adds to the DEBUG hook: `if env["COLOPHON_AUTO_MUTE"] == "1" { playback.muted = true }`.)

- [ ] **Step 6: Run everything** — `make test` (PlayerEngine now ≥ 19 tests incl. 7 new controller tests; ABSKit unchanged), `make build-ios`, `make build-mac`. Then a short headless E2E smoke on the iOS simulator (AUTO_CONNECT/AUTO_PLAY/**AUTO_MUTE=1**/AUTO_SEEK across the boundary as in M0) to prove the AVQueuePlayerBackend refactor didn't regress: server progress advances continuously across the 506.775s boundary. **Terminate the app afterward** (`xcrun simctl terminate booted com.andrewthom.colophon`).

- [ ] **Step 7: Commit** — `git add Packages/PlayerEngine App && git commit -m "refactor(PlayerEngine): PlayerBackend seam; unit-tested controller; mute hook"`

---

### Task 5: PlaybackSessionHandle — close/flush lifecycle + 404 recovery

**Files:**
- Modify: `Packages/ABSKit/Sources/ABSKit/ABSClient.swift` (`startPlayback` → envelope; add `postLocalSession`)
- Create: `Packages/ABSKit/Sources/ABSKit/PlaybackSessionHandle.swift`
- Create: `Packages/ABSKit/Tests/ABSKitTests/PlaybackSessionHandleTests.swift`
- Modify: `Packages/ABSKit/Tests/ABSKitTests/PlaybackEndpointTests.swift` + `ContractTests.swift` (envelope adaptation; contract lifecycle test adds close-verification)
- Modify: `App/AppState.swift`, `App/ColophonApp.swift` (ordering + scene-phase flush/close)

**Interfaces:**
- Produces: `PlaybackSessionEnvelope{session, rawData}`; `ABSClient.startPlayback(...) -> PlaybackSessionEnvelope`; `ABSClient.postLocalSession(rawData:currentTime:totalListened:)` → POST `api/session/local` with the original session JSON mutated: `currentTime`, `timeListening` (session total), `updatedAt` (now, ms). `PlaybackSessionHandle` per the contract block: `sync` returns true when the server acked (direct 200, or 404 → successful local upsert); accumulates `totalListened` internally; `close` posts `api/session/:id/close` with a final flush (falls back to local upsert on 404 too).
- Consumes: `ABSAPI`, `authorizedData` (401-retry path), Task 4's controller (`onSyncDue` now calls `handle.sync`).

- [ ] **Step 1: Write failing tests** — `PlaybackSessionHandleTests.swift`:

```swift
import Foundation
import Testing
@testable import ABSKit

@Suite struct PlaybackSessionHandleTests {
    let base = URL(string: "http://abs.test:13378")!
    let sessionJSON = #"{"id":"ses_1","libraryItemId":"li_1","duration":100,"playMethod":0,"startTime":0,"currentTime":0,"audioTracks":[],"chapters":[],"timeListening":0}"#

    private func makeSUT() async -> (PlaybackSessionHandle, MockTransport) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        let client = ABSClient(baseURL: base, transport: transport, auth: auth)
        let session = try! JSONDecoder().decode(PlaybackSession.self, from: Data(sessionJSON.utf8))
        let envelope = PlaybackSessionEnvelope(session: session, rawData: Data(sessionJSON.utf8))
        return (PlaybackSessionHandle(client: client, envelope: envelope), transport)
    }

    @Test func syncPostsAndAccumulates() async {
        let (handle, transport) = await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        #expect(await handle.sync(currentTime: 30, timeListened: 15) == true)
        let req = await transport.recorded.last
        #expect(req?.url?.path == "/api/session/ses_1/sync")
    }

    @Test func syncFallsBackToLocalUpsertOn404() async throws {
        let (handle, transport) = await makeSUT()
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

    @Test func failedLocalUpsertReturnsFalse() async {
        let (handle, transport) = await makeSUT()
        await transport.enqueue(status: 404, json: "{}")
        await transport.enqueue(status: 500, json: "{}")
        #expect(await handle.sync(currentTime: 10, timeListened: 10) == false)
    }

    @Test func closePostsFinalPayload() async {
        let (handle, transport) = await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        await handle.close(currentTime: 42, timeListened: 3)
        let req = await transport.recorded.last
        #expect(req?.url?.path == "/api/session/ses_1/close")
        let body = try? JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as? [String: Double]
        #expect(body?["currentTime"] == 42)
    }
}
```

- [ ] **Step 2: Run to verify failure** (types missing).

- [ ] **Step 3: Implement.** In `ABSClient.swift`: change `startPlayback` to capture the raw response data (use `authorizedData` directly, decode + keep bytes):

```swift
public struct PlaybackSessionEnvelope: Sendable {
    public let session: PlaybackSession
    public let rawData: Data
    public init(session: PlaybackSession, rawData: Data) { self.session = session; self.rawData = rawData }
}

// in ABSClient:
public func startPlayback(itemID: String, deviceInfo: DeviceInfo) async throws -> PlaybackSessionEnvelope {
    // (build req exactly as before)
    let data = try await authorizedData(req)
    let session = try ABSAPI.decoder.decode(PlaybackSession.self, from: data)
    return PlaybackSessionEnvelope(session: session, rawData: data)
}

public func postLocalSession(rawData: Data, currentTime: Double, totalListened: Double) async throws {
    guard var object = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
        throw ABSError.invalidResponse
    }
    object["currentTime"] = currentTime
    object["timeListening"] = totalListened
    object["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
    var req = URLRequest(url: baseURL.appending(path: "api/session/local"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: object)
    _ = try await authorizedData(req)
}
```

`PlaybackSessionHandle.swift`:

```swift
import Foundation

/// Owns one playback session's server lifecycle: periodic syncs, 404 recovery
/// (server restart wipes in-memory sessions), and close-with-flush.
public actor PlaybackSessionHandle {
    private let client: ABSClient
    private let envelope: PlaybackSessionEnvelope
    private var totalListened: Double

    public init(client: ABSClient, envelope: PlaybackSessionEnvelope) {
        self.client = client
        self.envelope = envelope
        self.totalListened = 0
    }

    public var sessionID: String { envelope.session.id }

    /// Returns true when the server acknowledged the listened time (directly or via local upsert).
    public func sync(currentTime: Double, timeListened: Double) async -> Bool {
        do {
            try await client.syncSession(id: envelope.session.id, currentTime: currentTime,
                                         timeListened: timeListened, duration: envelope.session.duration)
            totalListened += timeListened
            return true
        } catch ABSError.http(status: 404) {
            return await localUpsert(currentTime: currentTime, timeListened: timeListened)
        } catch {
            return false
        }
    }

    public func close(currentTime: Double, timeListened: Double) async {
        do {
            try await client.closeSession(id: envelope.session.id, currentTime: currentTime,
                                          timeListened: timeListened, duration: envelope.session.duration)
            totalListened += timeListened
        } catch ABSError.http(status: 404) {
            _ = await localUpsert(currentTime: currentTime, timeListened: timeListened)
        } catch {
            // Best-effort close; progress was carried by earlier syncs.
        }
    }

    private func localUpsert(currentTime: Double, timeListened: Double) async -> Bool {
        do {
            try await client.postLocalSession(rawData: envelope.rawData,
                                              currentTime: currentTime,
                                              totalListened: totalListened + timeListened)
            totalListened += timeListened
            return true
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 4: Wire the lifecycle in the app.** In `AppState`: hold `private var sessionHandle: PlaybackSessionHandle?`. `startPlayback(item:)` becomes (ordering is the point — final review Important #1):

```swift
func startPlayback(item: LibraryItemSummary) async {
    guard let client else { return }
    // 1. Retire the old session completely before touching the new one.
    if let old = sessionHandle {
        playback.pause()                       // triggers flush through onSyncDue → old handle
        playback.onSyncDue = nil
        await old.close(currentTime: playback.globalTime, timeListened: 0)
        playback.unload()
        sessionHandle = nil
    }
    do {
        let envelope = try await client.startPlayback(itemID: item.id, deviceInfo: deviceInfo)
        let handle = PlaybackSessionHandle(client: client, envelope: envelope)
        sessionHandle = handle
        playback.onSyncDue = { payload in
            await handle.sync(currentTime: payload.currentTime, timeListened: payload.timeListened)
        }
        let ordered = envelope.session.audioTracks.sorted { $0.startOffset < $1.startOffset }
        let urls = ordered.map { client.publicTrackURL(sessionID: envelope.session.id, trackIndex: $0.index) }
        playback.load(session: envelope.session, trackURLs: urls)
        playback.play()
    } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
}

func flushForBackground() { playback.pause() }   // pause() already flushes via onSyncDue

func closeCurrentSession() async {
    guard let handle = sessionHandle else { return }
    playback.pause()
    await handle.close(currentTime: playback.globalTime, timeListened: 0)
    sessionHandle = nil
}
```

In `ColophonApp.swift`: add `@Environment(\.scenePhase) private var scenePhase` and on the root Group: `.onChange(of: scenePhase) { _, phase in if phase == .background { app.flushForBackground() } }`. (Full close on termination is unreliable on iOS; background-flush + server-side 36h reaping + 404-recovery covers it — record this as the accepted semantic.)

Note: pausing on background is a deliberate M1a simplification to guarantee the flush; background AUDIO must keep playing, so gate it: only flush (not pause) when `playback.isPlaying` — implement `flushForBackground()` as `Task { await playback.flushOnly() }` where `flushOnly()` is a new public method on PlaybackController that calls `flushSync()` without pausing. Add that method in this task:

```swift
public func flushOnly() async { await flushSync() }
```

- [ ] **Step 5: Adapt existing tests + contract lifecycle.** `PlaybackEndpointTests.startPlaybackPostsDeviceInfoAndMimeTypes`: `let envelope = try await client.startPlayback(...)`; assertions on `envelope.session`. `ContractTests.fullPlaybackLifecycle`: use the envelope; after `closeSession`, add:

```swift
// Closed sessions are gone from server memory: sync must now 404.
await #expect(throws: ABSError.http(status: 404)) {
    try await client.syncSession(id: session.id, currentTime: 31, timeListened: 1, duration: session.duration)
}
```

- [ ] **Step 6: Run everything** — ABSKit suite (4 new handle tests + adaptations), contract suite against the dev server, `make build-ios build-mac`. Headless E2E (MUTED): play, wait ≥30s, then `docker restart colophon-abs`, wait ≥30s more → server progress still advances after restart (404 → local upsert path proven live). Terminate the app after.

- [ ] **Step 7: Commit** — `git add Packages/ABSKit App && git commit -m "feat(ABSKit): session lifecycle handle with close and 404 local-upsert recovery"`

---

### Task 6: LibraryCache package — schema, records, store, observation, FTS

**Files:**
- Create: `Packages/LibraryCache/Package.swift`, `Sources/LibraryCache/Schema.swift`, `Records.swift`, `LibraryCacheStore.swift`
- Create: `Packages/LibraryCache/Tests/LibraryCacheTests/LibraryCacheStoreTests.swift`
- Modify: `project.yml` (register package), `Makefile` (`test` target adds the package)

**Interfaces:**
- Produces: contract block above. Record shapes:
  `CachedConnection{id: String, address: String, name: String, username: String, authMethod: String, sortIndex: Int}`;
  `CachedLibrary{id, connectionID, name, mediaType, displayOrder: Int}`;
  `CachedItem{id, connectionID, libraryID, title, authorName: String?, duration: Double?, updatedAt: Int?}`;
  `CachedProgress{connectionID, itemID, episodeID: String?, currentTime: Double, isFinished: Bool, lastUpdate: Int}`.
  All `Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable`.

- [ ] **Step 1: Package.swift**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibraryCache",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LibraryCache", targets: ["LibraryCache"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "LibraryCache", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LibraryCacheTests", dependencies: ["LibraryCache"]),
    ]
)
```

- [ ] **Step 2: Write failing tests** — `LibraryCacheStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import LibraryCache

@Suite struct LibraryCacheStoreTests {
    private func makeStore() throws -> LibraryCacheStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LibraryCacheStore(databaseURL: dir.appending(path: "cache.sqlite"))
    }

    @Test func connectionsRoundTrip() throws {
        let store = try makeStore()
        let conn = CachedConnection(id: "C1", address: "http://s:1", name: "Home",
                                    username: "u", authMethod: "local", sortIndex: 0)
        try store.upsertConnection(conn)
        #expect(try store.connections() == [conn])
        var renamed = conn; renamed.name = "Home NAS"
        try store.upsertConnection(renamed)
        #expect(try store.connections() == [renamed])
    }

    @Test func itemsPageUpsertIsIdempotentAndOrdered() throws {
        let store = try makeStore()
        try store.upsertConnection(CachedConnection(id: "C1", address: "a", name: "n",
                                                    username: "u", authMethod: "local", sortIndex: 0))
        try store.upsertLibraries([CachedLibrary(id: "L1", connectionID: "C1", name: "Books",
                                                 mediaType: "book", displayOrder: 1)], connectionID: "C1")
        let a = CachedItem(id: "i1", connectionID: "C1", libraryID: "L1",
                           title: "Zebra", authorName: "A", duration: 10, updatedAt: 1)
        let b = CachedItem(id: "i2", connectionID: "C1", libraryID: "L1",
                           title: "Aardvark", authorName: "B", duration: 20, updatedAt: 1)
        try store.upsertItemsPage([a, b], connectionID: "C1", libraryID: "L1")
        try store.upsertItemsPage([a], connectionID: "C1", libraryID: "L1")   // re-page: no dupes
        let items = try store.items(connectionID: "C1", libraryID: "L1")
        #expect(items.map(\.id) == ["i2", "i1"])                              // title-ordered
    }

    @Test func progressUpsertKeepsNewest() throws {
        let store = try makeStore()
        let old = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                 currentTime: 10, isFinished: false, lastUpdate: 100)
        let newer = CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                   currentTime: 99, isFinished: false, lastUpdate: 200)
        try store.upsertProgress(old)
        try store.upsertProgress(newer)
        try store.upsertProgress(old)   // stale write must NOT clobber newer
        #expect(try store.progress(connectionID: "C1", itemID: "i1")?.currentTime == 99)
    }

    @Test func ftsFindsByTitleAndAuthorPrefix() throws {
        let store = try makeStore()
        try store.upsertItemsPage([
            CachedItem(id: "i1", connectionID: "C1", libraryID: "L1",
                       title: "The Art of War", authorName: "Sun Tzu", duration: 1, updatedAt: 1),
            CachedItem(id: "i2", connectionID: "C1", libraryID: "L1",
                       title: "Dracula", authorName: "Bram Stoker", duration: 1, updatedAt: 1),
        ], connectionID: "C1", libraryID: "L1")
        #expect(try store.searchItems(connectionID: "C1", query: "art").map(\.id) == ["i1"])
        #expect(try store.searchItems(connectionID: "C1", query: "stok").map(\.id) == ["i2"])
        #expect(try store.searchItems(connectionID: "C1", query: "zzz").isEmpty)
    }

    @Test func observationEmitsOnWrite() async throws {
        let store = try makeStore()
        let observation = store.observeLibraries(connectionID: "C1")
        var iterator = observation.makeAsyncIterator()
        _ = try await iterator.next()                                          // initial (empty) emission
        try store.upsertLibraries([CachedLibrary(id: "L1", connectionID: "C1", name: "Books",
                                                 mediaType: "book", displayOrder: 1)], connectionID: "C1")
        let next = try await iterator.next()
        #expect(next??.map(\.id) == ["L1"])
    }
}
```

(Also expose `items(connectionID:libraryID:)` and `progress(connectionID:itemID:)` plain fetches — the tests above use them.)

- [ ] **Step 3: Run to verify failure** (`cd Packages/LibraryCache && swift test` → FAIL).

- [ ] **Step 4: Implement.** `Schema.swift`:

```swift
import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "cachedConnection") { t in
                t.primaryKey("id", .text)
                t.column("address", .text).notNull()
                t.column("name", .text).notNull()
                t.column("username", .text).notNull()
                t.column("authMethod", .text).notNull()
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(table: "cachedLibrary") { t in
                t.primaryKey("id", .text)
                t.column("connectionID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("displayOrder", .integer).notNull()
            }
            try db.create(table: "cachedItem") { t in
                t.primaryKey("id", .text)
                t.column("connectionID", .text).notNull().indexed()
                t.column("libraryID", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("authorName", .text)
                t.column("duration", .double)
                t.column("updatedAt", .integer)
            }
            try db.create(table: "cachedProgress") { t in
                t.column("connectionID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("episodeID", .text)
                t.column("currentTime", .double).notNull()
                t.column("isFinished", .boolean).notNull()
                t.column("lastUpdate", .integer).notNull()
                t.primaryKey(["connectionID", "itemID"])
            }
            try db.create(virtualTable: "itemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "cachedItem")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("authorName")
            }
        }
        return migrator
    }
}
```

`Records.swift` — the four structs from the Interfaces block, each `Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable` with `static let databaseTableName` matching the schema (`"cachedConnection"` etc.; `CachedProgress` gets `var id: String { connectionID + "/" + itemID }`).

`LibraryCacheStore.swift`:

```swift
import Foundation
import GRDB

public struct LibraryCacheStore: Sendable {
    private let pool: DatabasePool

    public init(databaseURL: URL) throws {
        pool = try DatabasePool(path: databaseURL.path)
        try Schema.migrator.migrate(pool)
    }

    public func upsertConnection(_ c: CachedConnection) throws {
        try pool.write { try c.upsert($0) }
    }
    public func connections() throws -> [CachedConnection] {
        try pool.read { try CachedConnection.order(Column("sortIndex")).fetchAll($0) }
    }
    public func upsertLibraries(_ libs: [CachedLibrary], connectionID: String) throws {
        try pool.write { db in
            try CachedLibrary.filter(Column("connectionID") == connectionID
                                     && !libs.map(\.id).contains(Column("id"))).deleteAll(db)
            for lib in libs { try lib.upsert(db) }
        }
    }
    public func upsertItemsPage(_ items: [CachedItem], connectionID: String, libraryID: String) throws {
        try pool.write { db in for item in items { try item.upsert(db) } }
    }
    public func upsertProgress(_ p: CachedProgress) throws {
        try pool.write { db in
            if let existing = try CachedProgress.fetchOne(db, key: ["connectionID": p.connectionID,
                                                                    "itemID": p.itemID]),
               existing.lastUpdate > p.lastUpdate { return }   // last-write-wins by server timestamp
            try p.upsert(db)
        }
    }
    public func items(connectionID: String, libraryID: String) throws -> [CachedItem] {
        try pool.read {
            try CachedItem.filter(Column("connectionID") == connectionID && Column("libraryID") == libraryID)
                .order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll($0)
        }
    }
    public func progress(connectionID: String, itemID: String) throws -> CachedProgress? {
        try pool.read { try CachedProgress.fetchOne($0, key: ["connectionID": connectionID, "itemID": itemID]) }
    }
    public func observeLibraries(connectionID: String) -> AsyncValueObservation<[CachedLibrary]> {
        ValueObservation.tracking { db in
            try CachedLibrary.filter(Column("connectionID") == connectionID)
                .order(Column("displayOrder")).fetchAll(db)
        }.values(in: pool)
    }
    public func observeItems(connectionID: String, libraryID: String) -> AsyncValueObservation<[CachedItem]> {
        ValueObservation.tracking { db in
            try CachedItem.filter(Column("connectionID") == connectionID && Column("libraryID") == libraryID)
                .order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }.values(in: pool)
    }
    public func searchItems(connectionID: String, query: String) throws -> [CachedItem] {
        try pool.read { db in
            let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
            let sql = """
                SELECT cachedItem.* FROM cachedItem
                JOIN itemFTS ON itemFTS.rowid = cachedItem.rowid AND itemFTS MATCH ?
                WHERE cachedItem.connectionID = ?
                """
            return try CachedItem.fetchAll(db, sql: sql, arguments: [pattern, connectionID])
        }
    }
}
```

(GRDB 7 API details — `upsert`, `AsyncValueObservation`, FTS5 `synchronize(withTable:)` — verify against the resolved GRDB version's docs while implementing; adjust mechanically and record deviations. The TEST SEMANTICS are the contract.)

- [ ] **Step 5:** `project.yml`: add `LibraryCache: { path: Packages/LibraryCache }` under `packages:` and `- package: LibraryCache` under the target's dependencies. `Makefile` `test:` adds `cd Packages/LibraryCache && swift test`.

- [ ] **Step 6: Run** — package tests green; `make gen && make build-ios build-mac` still green.

- [ ] **Step 7: Commit** — `git add Packages/LibraryCache project.yml Makefile && git commit -m "feat(LibraryCache): GRDB store with FTS5 search and observations"`

---

### Task 7: Cache-backed browse + connection UUIDs + keychain migration + retry UX

**Files:**
- Modify: `App/AppState.swift` (becomes ConnectionManager-shaped), `App/Views/LibrariesView.swift`, `App/Views/LibraryItemsView.swift`

**Interfaces:**
- Consumes: `LibraryCacheStore` (Task 6), existing `ABSClient`/`AuthManager`.
- Produces: `AppState` gains `let cache: LibraryCacheStore` (database at `Application Support/Colophon/cache.sqlite`), `private(set) var activeConnectionID: String?` (UUID string). Connect flow: find-or-create a `CachedConnection` row matching (normalized address, username) → that row's UUID is the `connectionID` for AuthManager/Keychain. One-time migration: if Keychain has tokens under the legacy URL-string key and none under the UUID, move them. Views observe `cache.observeLibraries/observeItems`; network refresh writes into the cache (`upsertLibraries`, `upsertItemsPage` mapping `LibraryItemSummary` → `CachedItem`); list/grid failures show an inline "Couldn't load — Retry" button (no silent `try?`).

- [ ] **Step 1: Refactor `AppState.connect`** (URL normalization: trim whitespace, drop trailing "/", lowercase scheme+host via URLComponents):

```swift
let cache: LibraryCacheStore
// init: cache dir Application Support/Colophon; try! LibraryCacheStore(databaseURL: …/cache.sqlite)
// (a broken cache DB is unrecoverable dev-state — crash loudly rather than run split-brain)

func connect(serverURL: String, username: String, password: String) async {
    errorMessage = nil
    guard let url = normalizedServerURL(serverURL) else { errorMessage = "Invalid server URL"; return }
    phase = .connecting
    do {
        let transport = URLSessionTransport()
        let status = try await ABSClient.status(baseURL: url, transport: transport)
        guard status.isInit else { throw ABSError.invalidResponse }
        guard let vs = status.serverVersion, let v = ServerVersion(vs),
              !(v < ABSKit.minimumServerVersion) else {
            throw ABSError.serverTooOld(found: status.serverVersion ?? "unknown")
        }
        let connection = try findOrCreateConnection(address: url.absoluteString, username: username)
        migrateLegacyTokensIfNeeded(from: url.absoluteString, to: connection.id)
        let auth = AuthManager(baseURL: url, connectionID: connection.id,
                               transport: transport, store: tokenStore)
        _ = try await auth.login(username: username, password: password)
        let client = ABSClient(baseURL: url, transport: transport, auth: auth)
        self.auth = auth; self.client = client; self.activeConnectionID = connection.id
        try cache.upsertLibraries(try await client.libraries().enumerated().map { i, lib in
            CachedLibrary(id: lib.id, connectionID: connection.id, name: lib.name,
                          mediaType: lib.mediaType, displayOrder: lib.displayOrder ?? i)
        }, connectionID: connection.id)
        phase = .connected
    } catch ABSError.http(status: 401) { phase = .disconnected; errorMessage = "Wrong username or password" }
    catch { phase = .disconnected
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
}

private func findOrCreateConnection(address: String, username: String) throws -> CachedConnection {
    if let existing = try cache.connections().first(where: { $0.address == address && $0.username == username }) {
        return existing
    }
    let fresh = CachedConnection(id: UUID().uuidString, address: address,
                                 name: URL(string: address)?.host() ?? address,
                                 username: username, authMethod: "local",
                                 sortIndex: (try cache.connections().count))
    try cache.upsertConnection(fresh)
    return fresh
}

private func migrateLegacyTokensIfNeeded(from legacyKey: String, to newKey: String) {
    Task {
        if await tokenStore.tokens(for: newKey) == nil,
           let legacy = await tokenStore.tokens(for: legacyKey) {
            try? await tokenStore.save(legacy, for: newKey)
            await tokenStore.clear(for: legacyKey)
        }
    }
}
```

Also expose `func refreshItems(libraryID: String) async throws` that pages through `client.items` (limit 50, loop until `results.count` accumulated == `total`, hard cap 20 pages for M1a) mapping into `CachedItem(id:, connectionID:, libraryID:, title: media.metadata.title ?? "Untitled", authorName: media.metadata.authorName, duration: media.metadata… media.duration, updatedAt: updatedAt)` → `cache.upsertItemsPage`.

- [ ] **Step 2: Views observe the cache.** `LibrariesView`:

```swift
struct LibrariesView: View {
    @Environment(AppState.self) private var app
    @State private var libraries: [CachedLibrary] = []

    var body: some View {
        List(libraries) { library in
            NavigationLink(library.name, value: library)
        }
        .navigationTitle("Libraries")
        .fontDesign(.serif)
        .navigationDestination(for: CachedLibrary.self) { LibraryItemsView(library: $0) }
        .task(id: app.activeConnectionID) {
            guard let connectionID = app.activeConnectionID else { return }
            do {
                for try await value in app.cache.observeLibraries(connectionID: connectionID) {
                    libraries = value
                }
            } catch { app.errorMessage = "Library list unavailable: \(error.localizedDescription)" }
        }
    }
}
```

`LibraryItemsView` analogous: `@State private var items: [CachedItem]`, `.task(id:)` observing `observeItems`, plus a parallel `.task { await refresh() }` that calls `app.refreshItems(libraryID:)` with a `@State loadError: String?`; when `loadError != nil` show:

```swift
ContentUnavailableView {
    Label("Couldn't load library", systemImage: "wifi.exclamationmark")
} description: { Text(loadError ?? "") } actions: {
    Button("Retry") { Task { await refresh() } }
}
```

(Cover grid cell layout unchanged; `CachedLibrary` needs `Hashable` for the navigation value — it is, via Equatable+Codable synthesis with Hashable added to the record conformances in Task 6; if omitted there, add it now and note it.)

- [ ] **Step 3: Verify** — `make test && make build-ios && make build-mac`. Manual/headless evidence (all MUTED): (a) fresh connect → browse works; (b) relaunch with `docker stop colophon-abs` → libraries and items still render from cache (screenshot or log the observed cache counts); (c) `docker start colophon-abs`. Keychain migration: NOTE — the 2026-07-06 bundle-ID change also changed the Keychain service name, so no real legacy entries exist to migrate on dev machines; keep the migration code (it is the correct behavior for any hypothetical M0-era install) and verify the function with an in-memory-store unit test in ABSKitTests instead of a manual flow.

- [ ] **Step 4: Commit** — `git add App Packages && git commit -m "feat(app): cache-backed browse, connection UUIDs, keychain migration, retry UX"`

---

### Task 8: CoverStore — ts-keyed disk cover cache

**Files:**
- Create: `Packages/LibraryCache/Sources/LibraryCache/CoverStore.swift`
- Create: `Packages/LibraryCache/Tests/LibraryCacheTests/CoverStoreTests.swift`
- Create: `App/Views/CachedCoverView.swift`; Modify: `App/Views/LibraryItemsView.swift` (use it)

**Interfaces:**
- Produces: `CoverStore` actor (contract block). Disk layout `<dir>/<connectionID>/<itemID>-<updatedAt ?? 0>.img`; a hit returns disk bytes without calling `fetch`; a miss calls `fetch`, persists, and deletes any older `<itemID>-*.img` for that item. `CachedCoverView(itemID:updatedAt:)` renders via the store using `app.client.coverURL` + plain `URLSession` fetch closure.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
@testable import LibraryCache

@Suite struct CoverStoreTests {
    private func makeSUT() throws -> (CoverStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (CoverStore(directory: dir), dir)
    }

    @Test func fetchesOnceThenServesFromDisk() async throws {
        let (store, _) = try makeSUT()
        nonisolated(unsafe) var fetchCount = 0
        let fetch: @Sendable () async throws -> Data = { fetchCount += 1; return Data([1, 2, 3]) }
        let first = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 100, fetch: fetch)
        let second = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 100, fetch: fetch)
        #expect(first == Data([1, 2, 3]) && second == Data([1, 2, 3]))
        #expect(fetchCount == 1)
    }

    @Test func newerTimestampInvalidatesOldFile() async throws {
        let (store, dir) = try makeSUT()
        _ = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 100) { Data([1]) }
        _ = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 200) { Data([2]) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "C1").path)
        #expect(files == ["i1-200.img"])
        let cached = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 200) { Data([9]) }
        #expect(cached == Data([2]))
    }

    @Test func fetchErrorPropagatesAndCachesNothing() async throws {
        let (store, dir) = try makeSUT()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await store.coverData(connectionID: "C1", itemID: "i1", updatedAt: 1) { throw Boom() }
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "C1").path))?.isEmpty ?? true)
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `CoverStore.swift`**

```swift
import Foundation

public actor CoverStore {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func coverData(connectionID: String, itemID: String, updatedAt: Int?,
                          fetch: @Sendable () async throws -> Data) async throws -> Data {
        let ts = updatedAt ?? 0
        let connDir = directory.appending(path: connectionID)
        let file = connDir.appending(path: "\(itemID)-\(ts).img")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        let data = try await fetch()
        try FileManager.default.createDirectory(at: connDir, withIntermediateDirectories: true)
        if let stale = try? FileManager.default.contentsOfDirectory(atPath: connDir.path) {
            for name in stale where name.hasPrefix("\(itemID)-") {
                try? FileManager.default.removeItem(at: connDir.appending(path: name))
            }
        }
        try data.write(to: file, options: .atomic)
        return data
    }
}
```

- [ ] **Step 4: `CachedCoverView.swift`** — `@State private var image: Image?`; `.task(id:)` on `(itemID, updatedAt)` loading via `app.coverStore.coverData(...)` with `fetch: { try await URLSession.shared.data(from: coverURL).0 }`, converting through `UIImage`/`NSImage` (`#if os(macOS)`); placeholder `RoundedRectangle.fill(.quaternary)` while nil. AppState gains `let coverStore = CoverStore(directory: <Caches>/covers)`. Swap `AsyncImage` in `LibraryItemsView` for `CachedCoverView`.

- [ ] **Step 5: Run** — LibraryCache tests green; builds green; manual: browse once, stop server, relaunch → covers still render (from disk).

- [ ] **Step 6: Commit** — `git add Packages/LibraryCache App && git commit -m "feat(LibraryCache): ts-keyed disk cover cache + CachedCoverView"`

---

### Task 9: Auth housekeeping — tokenUpdates stream, logout test, keychain flag, version plumbing

**Files:**
- Modify: `Packages/ABSKit/Sources/ABSKit/AuthManager.swift`, `TokenStore.swift`
- Modify: `Packages/ABSKit/Tests/ABSKitTests/AuthManagerTests.swift`
- Modify: `project.yml` (Info.plist version keys), `App/AppState.swift` (clientVersion from bundle)

**Interfaces:**
- Produces: `AuthManager.tokenUpdates: AsyncStream<String>` — yields the new access token after every successful `login` and `refreshAfterAuthFailure` (single-consumer; Task 11 consumes it). `KeychainTokenStore` queries all include `kSecUseDataProtectionKeychain: true`. `Info.plist` uses `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`; `AppState.deviceInfo.clientVersion` reads `Bundle.main`.

- [ ] **Step 1: Write failing tests** — append to `AuthManagerTests`:

```swift
@Test func tokenUpdatesYieldOnLoginAndRefresh() async throws {
    let (auth, transport, store) = await makeSUT()
    var iterator = await auth.tokenUpdates.makeAsyncIterator()
    await transport.enqueue(status: 200, json: loginJSON)                       // acc1
    _ = try await auth.login(username: "root", password: "pw")
    #expect(await iterator.next() == "acc1")
    await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"root","accessToken":"acc2","refreshToken":"ref2"}}"#)
    _ = try await auth.refreshAfterAuthFailure(staleToken: "acc1")
    #expect(await iterator.next() == "acc2")
}

@Test func logoutPostsRefreshHeaderAndClears() async throws {
    let (auth, transport, store) = await makeSUT()
    await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
    await transport.enqueue(status: 200, json: "{}")
    await auth.logout()
    let req = await transport.recorded.last
    #expect(req?.url?.path == "/logout")
    #expect(req?.value(forHTTPHeaderField: "x-refresh-token") == "ref1")
    #expect(await store.tokens(for: "c1") == nil)
}
```

- [ ] **Step 2: Run to verify failure** (no `tokenUpdates`; logout test may pass already — if it does, note it as pre-verified and keep it).

- [ ] **Step 3: Implement.** In `AuthManager`:

```swift
public let tokenUpdates: AsyncStream<String>
private let tokenContinuation: AsyncStream<String>.Continuation
// in init:
(tokenUpdates, tokenContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
// after successful store.save in login: tokenContinuation.yield(access)
// after successful store.save in the refresh task: capture the continuation in the closure list and yield(access)
```

In `KeychainTokenStore.baseQuery`, add `kSecUseDataProtectionKeychain as String: true`. In `project.yml` `info.properties` add `CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`. In `AppState.deviceInfo`: `clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"`.

- [ ] **Step 4: Run** — ABSKit suite green; `make gen && make build-ios build-mac`; on the Mac build, sanity-launch once (MUTED, terminate after) to confirm keychain reads/writes still work with the new flag (data-protection keychain is a different store — the Task 7 migration path plus fresh login covers it; if the launch shows a re-login is needed once, that is EXPECTED and must be stated in the report, not hidden).

- [ ] **Step 5: Commit** — `git add Packages/ABSKit project.yml App && git commit -m "feat(ABSKit): token-update stream, data-protection keychain, version plumbing"`

---

### Task 10: ABSRealtime — ServerEvent decoding + SocketService

**Files:**
- Modify: `Packages/ABSKit/Package.swift` (add socket.io dependency + ABSRealtime target/product)
- Create: `Packages/ABSKit/Sources/ABSRealtime/ServerEvent.swift`, `SocketService.swift`
- Create: `Packages/ABSKit/Tests/ABSRealtimeTests/ServerEventTests.swift`

**Interfaces:**
- Produces: contract block (`ProgressUpdate`, `ServerEvent`, `SocketService`). `ServerEvent.decode(event: String, payload: [Any]) -> ServerEvent?` is the pure, testable core: `"user_item_progress_updated"` payload `[{id, sessionId?, data: {libraryItemId, episodeId?, currentTime, isFinished, lastUpdate}}]` → `.progressUpdated`; `"item_updated"`/`"item_added"` payload `[{id, ...}]` → `.itemChanged(id:)`; `"items_updated"`/`"items_added"` payload `[[{id,...}]]` → `.itemsChanged(ids:)`; `"item_removed"` → `.itemRemoved(id:)`; unknown events → nil.
- Consumes: spike-verified config; `AuthManager.tokenUpdates` is consumed by the APP (Task 11), which calls `reauthenticate()`.

- [ ] **Step 1: Package.swift changes**

```swift
dependencies: [
    .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.0"),
],
products: [
    .library(name: "ABSKit", targets: ["ABSKit"]),
    .library(name: "ABSRealtime", targets: ["ABSRealtime"]),
],
targets: [
    .target(name: "ABSKit"),
    .target(name: "ABSRealtime",
            dependencies: ["ABSKit", .product(name: "SocketIO", package: "socket.io-client-swift")]),
    .testTarget(name: "ABSKitTests", dependencies: ["ABSKit"], resources: [.copy("Fixtures")]),
    .testTarget(name: "ABSRealtimeTests", dependencies: ["ABSRealtime"]),
]
```

- [ ] **Step 2: Write failing decode tests** — `ServerEventTests.swift`:

```swift
import Foundation
import Testing
@testable import ABSRealtime

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}

@Suite struct ServerEventTests {
    @Test func decodesProgressUpdate() {
        let payload = json(#"{"id":"prog1","sessionId":"ses_1","data":{"libraryItemId":"li_1","episodeId":null,"currentTime":42.5,"isFinished":false,"lastUpdate":1751790000000,"duration":100}}"#)
        let event = ServerEvent.decode(event: "user_item_progress_updated", payload: [payload])
        #expect(event == .progressUpdated(ProgressUpdate(
            itemID: "li_1", episodeID: nil, currentTime: 42.5, isFinished: false, lastUpdate: 1751790000000)))
    }

    @Test func decodesItemLifecycleEvents() {
        #expect(ServerEvent.decode(event: "item_updated", payload: [json(#"{"id":"li_9"}"#)]) == .itemChanged(id: "li_9"))
        #expect(ServerEvent.decode(event: "item_added", payload: [json(#"{"id":"li_9"}"#)]) == .itemChanged(id: "li_9"))
        #expect(ServerEvent.decode(event: "item_removed", payload: [json(#"{"id":"li_9"}"#)]) == .itemRemoved(id: "li_9"))
        #expect(ServerEvent.decode(event: "items_updated",
                                   payload: [[json(#"{"id":"a"}"#), json(#"{"id":"b"}"#)]]) == .itemsChanged(ids: ["a", "b"]))
    }

    @Test func unknownOrMalformedYieldsNil() {
        #expect(ServerEvent.decode(event: "pong", payload: []) == nil)
        #expect(ServerEvent.decode(event: "user_item_progress_updated", payload: ["garbage"]) == nil)
        #expect(ServerEvent.decode(event: "item_updated", payload: [json(#"{"noID":true}"#)]) == nil)
    }
}
```

- [ ] **Step 3: Run to verify failure**, then implement `ServerEvent.swift`:

```swift
import Foundation

public struct ProgressUpdate: Sendable, Equatable {
    public let itemID: String
    public let episodeID: String?
    public let currentTime: Double
    public let isFinished: Bool
    public let lastUpdate: Int
    public init(itemID: String, episodeID: String?, currentTime: Double, isFinished: Bool, lastUpdate: Int) {
        self.itemID = itemID; self.episodeID = episodeID
        self.currentTime = currentTime; self.isFinished = isFinished; self.lastUpdate = lastUpdate
    }
}

public enum ServerEvent: Sendable, Equatable {
    case progressUpdated(ProgressUpdate)
    case itemChanged(id: String)
    case itemsChanged(ids: [String])
    case itemRemoved(id: String)

    public static func decode(event: String, payload: [Any]) -> ServerEvent? {
        switch event {
        case "user_item_progress_updated":
            guard let dict = payload.first as? [String: Any],
                  let data = dict["data"] as? [String: Any],
                  let itemID = data["libraryItemId"] as? String,
                  let currentTime = data["currentTime"] as? Double,
                  let lastUpdate = data["lastUpdate"] as? Int else { return nil }
            return .progressUpdated(ProgressUpdate(
                itemID: itemID,
                episodeID: data["episodeId"] as? String,
                currentTime: currentTime,
                isFinished: data["isFinished"] as? Bool ?? false,
                lastUpdate: lastUpdate))
        case "item_updated", "item_added":
            guard let dict = payload.first as? [String: Any], let id = dict["id"] as? String else { return nil }
            return .itemChanged(id: id)
        case "item_removed":
            guard let dict = payload.first as? [String: Any], let id = dict["id"] as? String else { return nil }
            return .itemRemoved(id: id)
        case "items_updated", "items_added":
            guard let array = payload.first as? [[String: Any]] else { return nil }
            let ids = array.compactMap { $0["id"] as? String }
            return ids.isEmpty ? nil : .itemsChanged(ids: ids)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Implement `SocketService.swift`** (spike-verified config; auth on every `.connect`, which also fires on reconnect):

```swift
import Foundation
import SocketIO

@MainActor
public final class SocketService {
    private let manager: SocketManager
    private let tokenProvider: @Sendable () async -> String?
    private var continuation: AsyncStream<ServerEvent>.Continuation?

    public init(serverURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        self.tokenProvider = tokenProvider
        self.manager = SocketManager(socketURL: serverURL, config: [
            .forceWebsockets(true), .version(.three), .compress,
            .reconnectWait(2), .reconnectWaitMax(10),
        ])
    }

    public func events() -> AsyncStream<ServerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        let socket = manager.defaultSocket
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in await self?.emitAuth() }
        }
        for name in ["user_item_progress_updated", "item_updated", "item_added",
                     "item_removed", "items_updated", "items_added"] {
            socket.on(name) { [weak self] payload, _ in
                Task { @MainActor in
                    if let event = ServerEvent.decode(event: name, payload: payload) {
                        self?.continuation?.yield(event)
                    }
                }
            }
        }
        socket.connect()
        return stream
    }

    /// Call after a token refresh: the server drops un-reauthenticated sockets' events.
    public func reauthenticate() async { await emitAuth() }

    public func stop() {
        continuation?.finish()
        manager.defaultSocket.disconnect()
    }

    private func emitAuth() async {
        guard let token = await tokenProvider() else { return }
        manager.defaultSocket.emit("auth", token)
    }
}
```

- [ ] **Step 5: Run** — `cd Packages/ABSKit && swift test` (existing + ABSRealtimeTests green; SocketIO compiles under strict concurrency — if the library's non-Sendable types need `@preconcurrency import SocketIO`, use it and record the deviation). `make gen && make build-ios build-mac` (app does not link ABSRealtime yet — Task 11 adds it).

- [ ] **Step 6: Commit** — `git add Packages/ABSKit && git commit -m "feat(ABSRealtime): socket service with typed server events"`

---

### Task 11: Socket → cache wiring + live UI

**Files:**
- Modify: `project.yml` (app links ABSRealtime), `App/AppState.swift`

**Interfaces:**
- Consumes: `SocketService` (Task 10), `AuthManager.tokenUpdates` (Task 9), `LibraryCacheStore.upsertProgress` (Task 6), `refreshItems` (Task 7).
- Produces: while connected, the app maintains one SocketService; `progressUpdated` events upsert `CachedProgress`; `itemChanged/itemsChanged/itemRemoved` trigger `refreshItems` for the active library (M1a: coarse refresh; per-item PATCH is M1c polish). Token refreshes re-auth the socket.

- [ ] **Step 1: project.yml** — under the Colophon target dependencies add `- package: ABSKit` product `ABSRealtime` (XcodeGen syntax: `- package: ABSKit\n  product: ABSRealtime`; keep the existing plain ABSKit dependency line too).

- [ ] **Step 2: Wire in `AppState`** (end of successful `connect`):

```swift
// Real-time updates: one socket per active connection.
socket?.stop()
let service = SocketService(serverURL: url) { [weak auth] in
    try? await auth?.currentAccessToken()
}
socket = service
socketTask?.cancel()
socketTask = Task { [weak self] in
    for await event in service.events() {
        await self?.apply(event)
    }
}
reauthTask?.cancel()
reauthTask = Task { [weak self] in
    guard let updates = self?.auth?.tokenUpdates else { return }
    for await _ in updates {
        await self?.socket?.reauthenticate()
    }
}
```

with:

```swift
private var socket: SocketService?
private var socketTask: Task<Void, Never>?
private var reauthTask: Task<Void, Never>?
private var activeLibraryID: String?          // set by LibraryItemsView via app.refreshItems

private func apply(_ event: ServerEvent) async {
    guard let connectionID = activeConnectionID else { return }
    switch event {
    case .progressUpdated(let update):
        try? cache.upsertProgress(CachedProgress(
            connectionID: connectionID, itemID: update.itemID, episodeID: update.episodeID,
            currentTime: update.currentTime, isFinished: update.isFinished, lastUpdate: update.lastUpdate))
    case .itemChanged, .itemsChanged, .itemRemoved:
        if let libraryID = activeLibraryID { try? await refreshItems(libraryID: libraryID) }
    }
}
```

(`refreshItems` records `activeLibraryID = libraryID` when called. `disconnect`/logout paths call `socket?.stop()` and cancel both tasks.)

- [ ] **Step 3: Live E2E evidence (the deliverable).** With the app running MUTED in the simulator, from a terminal:

```bash
TOKEN=$(curl -fsS -X POST http://localhost:13378/login -H 'Content-Type: application/json' \
  -H 'x-return-tokens: true' -d '{"username":"root","password":"colophon-dev"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"]["accessToken"])')
ITEM=$(curl -fsS "http://localhost:13378/api/libraries/$(curl -fsS http://localhost:13378/api/libraries \
  -H "Authorization: Bearer $TOKEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["libraries"][0]["id"])')/items?limit=1&minified=1" \
  -H "Authorization: Bearer $TOKEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')
curl -fsS -X PATCH "http://localhost:13378/api/me/progress/$ITEM" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"currentTime": 777, "duration": 4980, "progress": 0.156}'
```

then confirm the app received it: query the app's cache DB (`sqlite3 <sim-container>/Library/Application Support/Colophon/cache.sqlite "select currentTime from cachedProgress"` → `777.0` within ~2s). Also restart the container mid-run and confirm events resume after reconnect (spike says ≤10s with tuned backoff). Record all outputs. Terminate the app after.

- [ ] **Step 4: Run full suite + builds; commit** — `git add project.yml App && git commit -m "feat(app): live socket updates into the library cache"`

---

### Task 12: M1a wrap-up

**Files:**
- Modify: `README.md` (status), `.superpowers/sdd/progress.md` is controller-owned (skip)

**Interfaces:** none — closure task.

- [ ] **Step 1: README status** — update the **Status** paragraph to: password auth with version gate, cache-backed browsing (GRDB + FTS5) with offline reads, ts-keyed cover cache, unit-tested player core behind a backend seam, full session lifecycle (close + 404 recovery), live socket updates. Add `LibraryCache` to the dev commands note (`make test` covers three packages).
- [ ] **Step 2: Full verification sweep** — `make test && make build-ios && make build-mac`, then cold start (`make server-down && rm -rf devserver/data && make server-up && make seed`) and `ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests` from `Packages/ABSKit`. Everything green from factory-fresh.
- [ ] **Step 3: Commit** — `git add README.md && git commit -m "docs: M1a status"`. Tagging (`m1a-foundation`) is deferred to the controller after the final whole-branch review.

---

## Self-review notes (performed at plan-writing time)

- **Coverage vs M1a scope (overview doc):** all 12 overview bullets map to Tasks 1–12. Deliberately absent (later sub-plans): OIDC/Dex (M1b), settings + serif toggle UI (M1b), shelves/search-UI/item-detail/full player UX (M1c), simultaneous multi-server browsing (post-v1 per spec).
- **Known simplifications accepted for M1a** (recorded for M1b/M1c planning): socket item events trigger coarse library refresh, not per-item patch; `refreshItems` caps at 20 pages; progress is cached but not yet rendered in the grid (M1c shelves/badges); `connect` UI still only supports password auth; background flush relies on `flushOnly` + server reaping rather than guaranteed close-on-terminate.
- **Type consistency check:** `PlaybackSessionEnvelope` flows Task 5 → AppState; `CachedConnection/CachedLibrary/CachedItem/CachedProgress` shapes match between Tasks 6, 7, 8, 11; `tokenUpdates` (Task 9) consumed in Task 11; `PlayerBackend.volume` added in Task 4 and used by `muted`; `SessionSyncController.didSync` semantics (Task 2) relied on by Task 4's controller tests and Task 5's handle flow.
- **GRDB/SocketIO API drift risk:** both tasks carry explicit "verify against resolved version, adjust mechanically, record deviations" instructions; test semantics are the contract, not the exact library idiom.
