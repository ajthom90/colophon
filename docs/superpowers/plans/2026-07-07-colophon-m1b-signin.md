# Colophon M1b — Sign-in & Connections UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Colophon a real multi-server client: OIDC single sign-on, connection management with offline-capable first-run, a Settings scene with the serif/San Francisco typeface toggle — built on top of the cache/schema hardening the M1a final review mandated.

**Architecture:** Three phases inside one plan. (1) **Hardening first** (Tasks 1–4): composite cache PKs and deletion reconciliation *before* any connection-switch UI exists, plus an app-level test harness so AppState's state machine — where both M1a merge-gating bugs lived — is finally unit-tested. (2) **OIDC** (Tasks 5–7): a Dex IdP in the dev stack, a browser-agnostic `OIDCFlow` in ABSKit (the browser is an injected closure — ASWebAuthenticationSession in production, a scripted cookie-jar client in tests), and `/status`-driven sign-in UI. (3) **Connections & Settings** (Tasks 8–10): connection list/switch/remove/logout with cached-first activation (fixing the offline first-run gap), Settings + typography, background-flush protection.

**Tech Stack:** Swift 6.2, GRDB 7.11.1, socket.io-client-swift 16.1.1, ASWebAuthenticationSession (SwiftUI `webAuthenticationSession` environment), Dex (`ghcr.io/dexidp/dex`, pinned), Swift Testing, XcodeGen unit-test bundle.

## Global Constraints

- All M0/M1a constraints bind: deployment targets iOS/macOS 26.0; Xcode 26.6; strict concurrency; bundle ID `com.andrewthom.colophon` (team `LL334G7KP2`, automatic signing); server ≥ 2.26.0; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Headless E2E discipline: `COLOPHON_AUTO_MUTE=1` on every run; ALWAYS terminate the app afterward (`xcrun simctl terminate booted com.andrewthom.colophon` / kill the Mac process).
- OIDC custom scheme: exactly `colophon://oauth` (spec-locked; must be registered in project.yml `CFBundleURLTypes` and whitelisted in the dev server's Allowed Mobile Redirect URIs by the seed).
- **Playback policy on connection switch (decided):** switching the active connection does NOT interrupt playback — the `PlaybackSessionHandle` owns its own `ABSClient`, so the old session keeps syncing/closing correctly; retire happens on next play. Logout/remove of the connection that OWNS the playing session DOES retire it first, and any operation that deactivates a connection with a live socket calls `stopSocket()`.
- Settings keys (`@AppStorage`, exact): `colophon.typeface` ("serif" default | "sans"), `colophon.defaultRate` (Double, default 1.0), `colophon.skipInterval` (Int seconds, default 15, choices 10/15/30/45).
- Schema changes ship as an amended **v1** migration plus `#if DEBUG migrator.eraseDatabaseOnSchemaChange = true #endif` (GRDB's sanctioned dev pattern; no shipped databases exist). The v1 schema FREEZES at the end of M1b — record that in the wrap-up.
- Dev-server credentials: root / colophon-dev; OIDC test user (Dex static): `oidc@colophon.dev` / `colophon-oidc`.

## Shipped-reality contract block (supersedes the M1a plan's block — M1a final-review rec #6)

What actually shipped in M1a and binds this plan:

```swift
// ABSKit (shipped)
AuthManager: actor — login(username:password:), currentAccessToken(), refreshAfterAuthFailure(staleToken:),
  logout(), tokenUpdates: AsyncStream<String> (bufferingNewest(1), yields after successful login/refresh)
TokenStore.save is `async throws`; KeychainTokenStore uses kSecUseDataProtectionKeychain + keychain-access-groups
ABSClient.startPlayback -> PlaybackSessionEnvelope { session: PlaybackSession, rawData: Data }
ABSClient.postLocalSession(rawData:currentTime:totalListened:)
PlaybackSessionHandle: actor — sync(currentTime:timeListened:) async -> Bool (404 → local upsert), close(...)
TokenMigration.migrateLegacyTokensIfNeeded(from:to:store:) — clears legacy ONLY after successful save
ABSKit.minimumServerVersion == ServerVersion("2.26.0")!; ABSError incl. .serverTooOld(found:), all LocalizedError

// ABSRealtime (shipped)
ServerEvent: progressUpdated(ProgressUpdate) | progressBatch([ProgressUpdate]) | itemChanged(id:)
  | itemsChanged(ids:) | itemRemoved(id:)   // user_updated → progressBatch (mediaProgress array)
ProgressUpdate { itemID, episodeID: String?, currentTime, isFinished, lastUpdate: Int }
SocketService: @MainActor final class — events() (restart-safe: handlers once, supersedes prior stream),
  reauthenticate(), stop(); config .forceWebsockets(true), .version(.three), .compress, .reconnectWait(2), .reconnectWaitMax(10)

// LibraryCache (shipped)
CachedProgress: PK (connectionID, itemID, episodeID) with episodeID stored String, "" = book (init takes String?)
LibraryCacheStore: init creates parent dir; upsertItemsPage stamps connectionID/libraryID; searchItems ORDER BY rank
CoverStore: actor, write-before-delete, layout <dir>/<connectionID>/<itemID>-<ts ?? 0>.img

// App (shipped)
AppState (@MainActor @Observable): connect() [reentrancy-guarded, stopSocket+ID-nil prefix, version gate,
  find-or-create CachedConnection by normalized (address, username), awaited keychain migration],
  startPlayback(itemID:) [first-tap-wins guard, retireCurrentSession() ordering], retireCurrentSession(),
  flushForBackground() [flushOnly, no pause], apply(_ event:), stopSocket(), refreshItems(libraryID:) [50/page, 20-page cap]
```

## File Structure (M1b end state; new/changed only)

```
devserver/docker-compose.yml            + dex service (pinned) on 5556, shared network
devserver/dex/config.yaml               NEW — issuer, static client (audiobookshelf), static test user
devserver/seed.sh                       + OIDC server-settings configuration (empirically discovered endpoint)
docs/superpowers/spikes/2026-07-oidc-cookies.md   NEW — spike outcome (cookie requirements, endpoint findings)
Packages/ABSKit/Sources/ABSKit/ServerVersion.swift     pre-release suffix tolerance
Packages/ABSKit/Sources/ABSKit/Transport.swift         URLSessionTransport(followRedirects:) no-redirect option
Packages/ABSKit/Sources/ABSKit/OIDCFlow.swift          NEW — PKCE, authorize-capture, callback exchange
Packages/ABSKit/Sources/ABSKit/AuthManager.swift       + completeOIDC(loginResponse:) storing the pair
Packages/ABSKit/Sources/ABSKitTestSupport/             NEW target: MockTransport + helpers (shared with app tests)
Packages/LibraryCache/Sources/LibraryCache/Schema.swift        v1 amended: composite PKs; DEBUG erase-on-change
Packages/LibraryCache/Sources/LibraryCache/LibraryCacheStore.swift  deleteItem, replaceItems, upsertProgressBatch, init recovery
App/ColophonTests/                       NEW hosted unit-test bundle (AppState state machine)
App/AppState.swift                       transport/socket seams; activateConnection; logout/remove; refresh banner state
App/Views/ConnectionsView.swift          NEW — list/switch/add/remove/sign-out; first-run entry
App/Views/ConnectView.swift              /status-driven: password and/or OIDC button (authFormData)
App/Views/SettingsView.swift             NEW — typeface, default rate, skip interval
App/Views/RefreshBanner.swift            NEW — non-blocking refresh-failure banner
App/ColophonApp.swift                    root fontDesign from setting; Settings scene (macOS); boot → ConnectionsView
project.yml                              CFBundleURLTypes (colophon), ColophonTests target, scheme test action
Makefile                                 + test-app target
```

---

### Task 1: LibraryCache v2 hardening — composite PKs, deletion, reconciliation, batch progress, init recovery

**Files:**
- Modify: `Packages/LibraryCache/Sources/LibraryCache/Schema.swift`, `LibraryCacheStore.swift`, `Records.swift` (if key helpers needed)
- Modify: `Packages/LibraryCache/Tests/LibraryCacheTests/LibraryCacheStoreTests.swift`

**Interfaces:**
- Produces (Tasks 3/4/8 rely on): amended v1 schema — `cachedItem` PK `["connectionID","id"]`, `cachedLibrary` PK `["connectionID","id"]` (same server IDs under two connections coexist); `#if DEBUG` `migrator.eraseDatabaseOnSchemaChange = true` `#endif` in `Schema.migrator`;
  `func deleteItem(connectionID: String, itemID: String) throws` (FTS row goes via synchronize triggers);
  `func replaceItems(_ items: [CachedItem], connectionID: String, libraryID: String) throws` — ONE transaction: delete rows in (connectionID, libraryID) absent from the new list, upsert the rest (stamping as today). Progress rows are NOT touched (server owns their lifecycle);
  `func upsertProgressBatch(_ batch: [CachedProgress]) throws` — ONE transaction; per row, skip when existing `lastUpdate >= new.lastUpdate` (note: `>=`, stronger than single-row `>`, so unchanged rows don't churn observers);
  init recovery: if `DatabasePool`/migrate throws, delete the database file (+ `-wal`/`-shm` siblings), retry once; second failure rethrows.
- All existing call sites keep compiling: fetches by bare `fetchOne(db, key: id)` for items/libraries must become composite-key or filter-based — sweep the store.

- [ ] **Step 1: Write the failing tests** — append to the existing suite (existing 9 tests must pass unchanged except where PK semantics legitimately change them — none should):

```swift
@Test func sameServerIDsCoexistAcrossConnections() throws {
    let store = try makeStore()
    let a = CachedItem(id: "i1", connectionID: "C1", libraryID: "L1", title: "A", authorName: nil, duration: 1, updatedAt: 1)
    let b = CachedItem(id: "i1", connectionID: "C2", libraryID: "L1", title: "B", authorName: nil, duration: 1, updatedAt: 1)
    try store.upsertItemsPage([a], connectionID: "C1", libraryID: "L1")
    try store.upsertItemsPage([b], connectionID: "C2", libraryID: "L1")
    #expect(try store.items(connectionID: "C1", libraryID: "L1").map(\.title) == ["A"])
    #expect(try store.items(connectionID: "C2", libraryID: "L1").map(\.title) == ["B"])   // not clobbered
}

@Test func deleteItemRemovesRowAndFTS() throws {
    let store = try makeStore()
    try store.upsertItemsPage([CachedItem(id: "i1", connectionID: "C1", libraryID: "L1",
                                          title: "Dracula", authorName: nil, duration: 1, updatedAt: 1)],
                              connectionID: "C1", libraryID: "L1")
    try store.deleteItem(connectionID: "C1", itemID: "i1")
    #expect(try store.items(connectionID: "C1", libraryID: "L1").isEmpty)
    #expect(try store.searchItems(connectionID: "C1", query: "drac").isEmpty)
}

@Test func replaceItemsReconcilesAbsentRows() throws {
    let store = try makeStore()
    let keep = CachedItem(id: "i1", connectionID: "C1", libraryID: "L1", title: "Keep", authorName: nil, duration: 1, updatedAt: 1)
    let gone = CachedItem(id: "i2", connectionID: "C1", libraryID: "L1", title: "Gone", authorName: nil, duration: 1, updatedAt: 1)
    let other = CachedItem(id: "i9", connectionID: "C2", libraryID: "L1", title: "OtherConn", authorName: nil, duration: 1, updatedAt: 1)
    try store.upsertItemsPage([keep, gone], connectionID: "C1", libraryID: "L1")
    try store.upsertItemsPage([other], connectionID: "C2", libraryID: "L1")
    try store.replaceItems([keep], connectionID: "C1", libraryID: "L1")
    #expect(try store.items(connectionID: "C1", libraryID: "L1").map(\.id) == ["i1"])
    #expect(try store.items(connectionID: "C2", libraryID: "L1").map(\.id) == ["i9"])     // scoped: untouched
}

@Test func progressBatchSkipsStaleAndUnchanged() throws {
    let store = try makeStore()
    try store.upsertProgress(CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil,
                                            currentTime: 50, isFinished: false, lastUpdate: 200))
    try store.upsertProgressBatch([
        CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil, currentTime: 10, isFinished: false, lastUpdate: 100), // stale
        CachedProgress(connectionID: "C1", itemID: "i1", episodeID: nil, currentTime: 50, isFinished: false, lastUpdate: 200), // unchanged (>= skips)
        CachedProgress(connectionID: "C1", itemID: "i2", episodeID: nil, currentTime: 7, isFinished: false, lastUpdate: 300),  // new
    ])
    #expect(try store.progress(connectionID: "C1", itemID: "i1")?.currentTime == 50)
    #expect(try store.progress(connectionID: "C1", itemID: "i2")?.currentTime == 7)
}

@Test func corruptDatabaseFileRecoversFresh() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dbURL = dir.appending(path: "cache.sqlite")
    try Data("this is not a sqlite database".utf8).write(to: dbURL)
    let store = try LibraryCacheStore(databaseURL: dbURL)   // must not throw: delete-and-recreate
    #expect(try store.connections().isEmpty)
}
```

- [ ] **Step 2: Run to verify failure** — `cd Packages/LibraryCache && swift test` → new tests fail (missing APIs / single-column PK clobbering).
- [ ] **Step 3: Implement.** Schema: amend v1 `cachedItem`/`cachedLibrary` to `t.primaryKey(["connectionID","id"])` (columns unchanged); add the DEBUG erase-on-change flag right after `var migrator = DatabaseMigrator()`. Store: composite-key fetches (`filter(Column("connectionID") == c && Column("id") == id)`), the three new methods (all single `pool.write` transactions; `replaceItems` deletes via `filter(connectionID == c && libraryID == l && !ids.contains(Column("id")))`), and wrap the existing init body in a recovery attempt:

```swift
public init(databaseURL: URL) throws {
    try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    do {
        pool = try Self.openAndMigrate(at: databaseURL)
    } catch {
        // Corrupt or incompatible store: the cache is reconstructable from the server — recreate.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        pool = try Self.openAndMigrate(at: databaseURL)
    }
}
private static func openAndMigrate(at url: URL) throws -> DatabasePool {
    let pool = try DatabasePool(path: url.path)
    try Schema.migrator.migrate(pool)
    return pool
}
```

- [ ] **Step 4: Run** — LibraryCache 14/14 (9 + 5); `make test`; `make gen && make build-ios && make build-mac` (app still compiles against the store).
- [ ] **Step 5: Commit** — `git commit -m "feat(LibraryCache): composite PKs, deletion, reconciliation, batched progress, init recovery"`

---

### Task 2: ABSKit polish — ServerVersion suffixes, no-redirect transport, test-support target

**Files:**
- Modify: `Packages/ABSKit/Sources/ABSKit/ServerVersion.swift`, `Transport.swift`, `Package.swift`
- Create: `Packages/ABSKit/Sources/ABSKitTestSupport/MockTransport.swift` (moved + made public)
- Modify: `Packages/ABSKit/Tests/ABSKitTests/*` (import the moved MockTransport), `ServerVersionTests.swift`

**Interfaces:**
- Produces: `ServerVersion("2.36.0-beta.1")` == `ServerVersion("2.36.0")` (split on the first `-` or `+`, parse the core triplet; still nil for junk/2-part). `URLSessionTransport(followRedirects: Bool = true)` — when false, a session delegate returns nil from `willPerformHTTPRedirection`, so 3xx responses surface with their `Location`/`Set-Cookie` headers (OIDCFlow needs the 302 itself). New library product `ABSKitTestSupport` (target deps: ABSKit) exposing `public actor MockTransport` (same FIFO enqueue/recorded API — used by ABSKitTests AND the app test bundle in Task 3). ABSKitTests drops its private copy and depends on the product.

- [ ] **Step 1: Failing tests** — extend `ServerVersionTests`:

```swift
@Test func toleratesPreReleaseAndBuildSuffixes() {
    #expect(ServerVersion("2.36.0-beta.1") == ServerVersion("2.36.0"))
    #expect(ServerVersion("2.36.0+build5") == ServerVersion("2.36.0"))
    #expect(ServerVersion("2.36.0-beta")! > ServerVersion("2.26.0")!)
    #expect(ServerVersion("2.36-beta") == nil)
}
```

and a new `TransportRedirectTests` in ABSKitTests asserting `URLSessionTransport(followRedirects: false)` is constructible plus a unit-level check of the delegate method's return (nil) via direct invocation; the LIVE 302 behavior is exercised in Task 5's spike and Task 6's contract-style test.

- [ ] **Step 2–4:** FAIL → implement → PASS (`swift test` in ABSKit: same counts + new; both test targets compile against ABSKitTestSupport). `make gen && make build-ios && make build-mac`.
- [ ] **Step 5: Commit** — `git commit -m "feat(ABSKit): version suffixes, no-redirect transport, shared test support"`

---

### Task 3: Colophon unit-test bundle + AppState state-machine tests

**Files:**
- Modify: `project.yml` (ColophonTests target `type: bundle.unit-test`, depends on + hosted by Colophon; scheme gains a test action), `Makefile` (`test-app: xcodebuild test -project Colophon.xcodeproj -scheme Colophon -destination 'platform=iOS Simulator,name=$(SIM)' -allowProvisioningUpdates | tail -8`)
- Modify: `App/AppState.swift` — seams: `init(transportProvider: @escaping @Sendable () -> Transport = { URLSessionTransport() }, socketFactory: ...)`; the socket seam is a factory closure `(URL, @escaping @Sendable () async -> String?) -> any RealtimeSocketProtocol` where `RealtimeSocketProtocol` (`@MainActor protocol` in ABSRealtime: `events() -> AsyncStream<ServerEvent>`, `reauthenticate() async`, `stop()`) is adopted by `SocketService`.
- Create: `App/ColophonTests/AppStateTests.swift` (+ `FakeSocket.swift` conforming to the protocol)

**Interfaces:**
- Consumes: `MockTransport` from ABSKitTestSupport; a temp-dir `LibraryCacheStore` (AppState also needs a cache seam: `init(cacheDirectory: URL = <default App Support>)` so tests get isolated stores).
- Produces: `make test-app` green with AT MINIMUM these behaviors pinned (each a separate @MainActor @Test): (1) old-server /status → phase .disconnected + serverTooOld message; (2) second connect() while .connecting returns without a second /status request; (3) two startPlayback calls → exactly ONE /play request (first-tap-wins); (4) connect() with same normalized address+username twice → ONE CachedConnection row; (5) failed login → activeConnectionID nil; (6) apply(.progressBatch) lands rows in the cache (temp store); (7) apply(.itemRemoved) deletes the row (wired in Task 4 — write the test here as the RED driver for Task 4 and mark it `.disabled("wired in Task 4")` if sequencing demands, then enable it there).

- [ ] Steps: project.yml target + scheme → failing tests (compile-level RED against missing seams) → implement seams (default args preserve all production call sites; `ColophonApp` unchanged) → GREEN via `make test-app` → run FULL verification (`make test && make test-app && make build-ios && make build-mac`) → commit `feat(app): unit-test bundle and AppState seams + state-machine tests`.
- Note: keep DEBUG auto-connect hooks working; tests must not depend on env.

---

### Task 4: Deletion + reconciliation wiring, refresh banner, alert-title cleanup

**Files:**
- Modify: `App/AppState.swift` (`apply(.itemRemoved)` → `cache.deleteItem` then coarse refresh; `refreshItems` uses `replaceItems` when the page-through COMPLETED uncapped, else falls back to `upsertItemsPage`; new `var refreshBanner: String?` set on refresh failure when cache non-empty, cleared on success)
- Create: `App/Views/RefreshBanner.swift` (small top-overlay banner with message + Retry button; pattern-match the existing ContentUnavailableView styling)
- Modify: `App/Views/LibraryItemsView.swift` (banner when `refreshBanner != nil` AND items non-empty; ContentUnavailableView only when empty), `App/ColophonApp.swift` (alert title "Something went wrong" instead of "Playback error"; playback errors keep context via message text)
- Modify: `App/ColophonTests/AppStateTests.swift` (enable/extend: itemRemoved deletes; refresh failure with non-empty cache sets banner not error-alert)

**Interfaces:** consumes Task 1's `deleteItem`/`replaceItems` and Task 3's harness. Produces: server-deleted items disappear live; ghost-item accretion impossible after a completed refresh.

- [ ] Steps: failing harness tests → wire → GREEN → live E2E leg (dev server up: `curl -X DELETE http://localhost:13378/api/items/<id> -H "Authorization: Bearer $TOKEN"` on a seeded item while the MUTED app browses → sqlite shows the row gone ≤2s after the socket event; then `make seed` restores... note: DELETE removes files server-side; instead ADD a second book in the seed for this leg, or restore by re-running seed after — document what you did) → full suite/builds → commit `feat(app): live deletion reconciliation and refresh banner`.

---

### Task 5: Dex IdP + ABS OIDC configuration + cookie spike

**Files:**
- Create: `devserver/dex/config.yaml`; Modify: `devserver/docker-compose.yml`, `devserver/seed.sh`
- Create: `docs/superpowers/spikes/2026-07-oidc-cookies.md`

**Interfaces:**
- Produces: `make server-up && make seed` yields an ABS with BOTH auth methods active (`GET /status` → authMethods ["local","openid"]) against a Dex issuer reachable from the ABS container AND from host/simulator browsers; the spike doc answers M0's open question (does `GET /auth/openid/callback` require cookies from the initial `GET /auth/openid`? what exactly must the client carry?) with a full curl transcript, plus the empirically discovered ABS settings endpoint/payload for OIDC config.

Dex config (starting point — adjust empirically and record):

```yaml
issuer: http://host.docker.internal:5556/dex
storage: { type: memory }
web: { http: 0.0.0.0:5556 }
staticClients:
  - id: audiobookshelf
    secret: colophon-dex-secret
    name: Audiobookshelf
    redirectURIs:
      - http://localhost:13378/auth/openid/callback
      - http://localhost:13378/auth/openid/mobile-redirect
enablePasswordDB: true
staticPasswords:
  - email: oidc@colophon.dev
    hash: "$2a$10$..."          # bcrypt of "colophon-oidc" — generate during implementation (htpasswd -bnBC 10)
    username: oidc
    userID: 1d1c1e0a-0000-4000-8000-000000000001
```

**Networking (the known hard part — resolve empirically, document the final answer):** the issuer URL must validate for the ABS container AND be openable by the host browser/simulator. Preferred: issuer `http://host.docker.internal:5556/dex` with dex's 5556 published; ABS container resolves `host.docker.internal` natively. The HOST cannot resolve that name unless mapped — check `grep host.docker.internal /etc/hosts`; if absent, this task PAUSES and reports NEEDS_CONTEXT asking the user to run `echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts` (do NOT attempt sudo yourself). Fallback design if that's unacceptable: dex joins the compose network with issuer `http://localhost:5556/dex` and ABS gets `extra_hosts: ["localhost:host-gateway"]` — messier; document whichever wins and why.

Seed additions (after login):
1. Discover the settings endpoint from the running server (the web admin UI drives it — likely `PATCH /api/settings` with `authActiveAuthMethods`, `authOpenIDIssuerURL`, `authOpenIDClientID`, `authOpenIDClientSecret`, `authOpenIDMobileRedirectURIs: ["colophon://oauth"]`, plus autoLaunch/buttonText fields; confirm against server source in the container or GitHub at v2.35.1 and RECORD the exact payload in the spike doc).
2. Configure; verify `GET /status` reports both methods + `authFormData.authOpenIDButtonText`.

Spike (curl, cookie jar): full code-flow walk — `GET /auth/openid?...` (capture 302 Location + any Set-Cookie) → follow to Dex → POST the login form → capture redirect chain through `/auth/openid/mobile-redirect` → extract `colophon://oauth?code&state` → `GET /auth/openid/callback?state&code&code_verifier` twice: once WITH the cookie jar, once WITHOUT → record which succeeds. That answer shapes Task 6's session handling (the flow already keeps a cookie jar; the spike tells us if it's load-bearing).

- [ ] Steps: compose+config → `make server-up` (dex healthy: `curl http://host.docker.internal:5556/dex/.well-known/openid-configuration`) → seed OIDC config → spike transcript → doc → verify password login STILL works (contract suite green) → commit `feat(devserver): Dex OIDC provider + ABS OIDC config + cookie spike`.

---

### Task 6: ABSKit OIDCFlow

**Files:**
- Create: `Packages/ABSKit/Sources/ABSKit/OIDCFlow.swift`
- Modify: `Packages/ABSKit/Sources/ABSKit/AuthManager.swift` (`completeOIDC(loginResponse:)`)
- Create: `Packages/ABSKit/Tests/ABSKitTests/OIDCFlowTests.swift`

**Interfaces:**
- Produces:

```swift
public struct OIDCFlow: Sendable {
    public init(serverURL: URL, clientID: String = "Colophon", scheme: String = "colophon")
    /// Runs the full flow. `browser` receives the IdP authorize URL and must return the
    /// colophon://oauth?code=...&state=... callback URL (ASWebAuthenticationSession in the app;
    /// a scripted cookie-jar client in tests/E2E).
    public func authenticate(browser: @Sendable (URL) async throws -> URL) async throws -> LoginResponse
}
public enum OIDCError: Error, Equatable, LocalizedError { case serverRejected(status: Int), missingAuthorizeURL,
    stateMismatch, callbackMissingCode, exchangeFailed(status: Int) }
// AuthManager:
public func completeOIDC(loginResponse: LoginResponse) async throws  // stores TokenPair, yields tokenUpdates
```

Implementation notes (binding): PKCE verifier = 42 random bytes hex (84 chars, official-app-compatible); challenge = base64url(SHA256(verifier)) no padding; step-1 GET built with code_challenge/method=S256/redirect_uri=`colophon://oauth`/client_id/response_type=code via a **dedicated cookie-jar URLSession** with redirects DISABLED (Task 2 transport) — expect 302, capture `Location` (the IdP authorize URL; if the server returns non-3xx → `.serverRejected`); extract `state` from the Location's query (server-generated) and REQUIRE the browser-returned callback's `state` to equal it (`.stateMismatch`); exchange via GET `/auth/openid/callback?state&code&code_verifier` through the SAME cookie-jar session (per the Task 5 spike's findings); decode `LoginResponse`, require accessToken.

- [ ] Steps: failing unit tests with MockTransport scripting {302 w/ Location+state, browser closure returning matching/mismatched state, exchange 200/401} + a PKCE known-vector test (fixed verifier → expected challenge; make the generator injectable `init(..., verifier: String? = nil)` for tests) → implement → GREEN → an env-gated CONTRACT test `OIDCContractTests` (enabled when `ABS_CONTRACT_URL` set AND `/status` advertises openid) running `authenticate` with a scripted curl-equivalent browser (URLSession cookie jar walking the Dex form per the spike transcript) against the dev stack → all suites/builds → commit `feat(ABSKit): OIDC PKCE flow with injectable browser`.

---

### Task 7: OIDC in the app — scheme, /status-driven ConnectView, ASWebAuthenticationSession

**Files:**
- Modify: `project.yml` (info.properties `CFBundleURLTypes: [{CFBundleURLName: com.andrewthom.colophon.oauth, CFBundleURLSchemes: [colophon]}]`)
- Modify: `App/Views/ConnectView.swift` — two-step: enter server URL → app fetches `/status` → renders password form and/or OIDC button per `authMethods`/`authFormData` (button label `authOpenIDButtonText ?? "Sign in with SSO"`; honor `authOpenIDAutoLaunch` by launching the browser immediately)
- Modify: `App/AppState.swift` — `connectWithOIDC(serverURL:)`: same prefix as connect() (guards, stopSocket, normalize, version gate, find-or-create with authMethod "openid") then `OIDCFlow.authenticate(browser:)` with a closure using `@Environment(\.webAuthenticationSession)` handed in from the view (`session.authenticate(using: url, callbackURLScheme: "colophon")`), then `auth.completeOIDC(...)`, then the existing libraries/socket tail — extract the shared tail from connect() into a private helper rather than duplicating.
- Modify: `App/ColophonTests/AppStateTests.swift` (OIDC path: version gate + find-or-create + tail run with a fake browser closure; no real browser in unit tests)

**Interfaces:** consumes OIDCFlow (Task 6), status-form data already in `ServerStatus` (fields exist since M0 — verify `authFormData` decoding covers `authOpenIDButtonText`/`authOpenIDAutoLaunch`; extend `ServerStatus` if the DTO lacks them, with fixture-based decode tests in ABSKitTests).

- [ ] Steps: DTO check/extend + failing harness tests → implement view + AppState path → `make test && make test-app && make build-ios && make build-mac` → **live E2E** on the iOS simulator (MUTED): scripted where possible (`idb` taps through ConnectView → OIDC button → Dex login form in the ASWebAuthenticationSession sheet — the Task 8/M1a agents used idb successfully; if the auth sheet resists automation, fall back to verifying the flow with the Task 6 contract test PLUS a manual-verification note for the user, honestly labeled) → terminate app → commit `feat(app): OIDC sign-in flow`.

---

### Task 8: Connections UX — list/switch/add/remove/sign-out, cached-first activation (offline first-run fix)

**Files:**
- Create: `App/Views/ConnectionsView.swift`; Modify: `App/ColophonApp.swift`, `App/AppState.swift`, `App/Views/LibrariesView.swift` (clear stale @State on id change)
- Modify: `App/ColophonTests/AppStateTests.swift`

**Interfaces:**
- Produces on AppState:
  - `func activateConnection(_ id: String) async` — set active + persist `colophon.lastActiveConnectionID` (KVS/AppStorage); load cached libraries IMMEDIATELY (phase `.connected` with new `private(set) var isOnline: Bool`); in the background: probe stored tokens (`POST /api/authorize`; 401 → single refresh via existing machinery; reauthRequired → `needsSignIn` state for that connection surfaced in UI), start socket on success (`isOnline = true`), network failure → stay cached-mode with `refreshBanner` + retry affordance. **This is the offline first-run fix: cached browsing without a live server.**
  - `func signOut(connectionID: String) async` — if that connection owns the playing session: `retireCurrentSession()`; if active: `stopSocket()`; clear tokens (`tokenStore.clear`); keep connection row + cache rows; mark needs-sign-in.
  - `func removeConnection(_ id: String) async` — signOut semantics first, then delete connection row + its cachedLibrary/cachedItem/cachedProgress rows (add `LibraryCache.deleteConnection(connectionID:)` — cascading deletes in ONE transaction — small addition to the store WITH a test) + CoverStore directory + keychain entry.
  - Boot flow: connections exist → ConnectionsView (auto-activate last-active if set); none → ConnectView. ConnectionsView rows: name, address, username, active indicator, needs-sign-in badge; swipe/context actions: Sign out / Remove (confirmation dialog); toolbar +: push ConnectView.
  - **Playback policy (Global Constraints) enforced and TESTED:** switch-active during playback does not touch the player; signOut/remove of the owning connection retires first.
- Harness tests: activate-offline serves cached rows (kill transport with a failing MockTransport); switch keeps `playback.isPlaying == true` (fake backend); signOut of owner retires (play request recorded then close recorded); remove purges cache rows + tokens.

- [ ] Steps: store addition (`deleteConnection`) with test → failing harness tests → implement → full suites/builds → live E2E (MUTED): connect to dev server, kill server (`docker stop colophon-abs`), relaunch app → ConnectionsView → activate → CACHED LIBRARY BROWSES OFFLINE (screenshot/sqlite evidence — the gap Task 7/M1a documented is now closed), banner shows; `docker start colophon-abs` → retry → online, socket resumes → terminate app → commit `feat(app): connection management with cached-first activation`.

---

### Task 9: Settings & typography

**Files:**
- Create: `App/Views/SettingsView.swift`; Modify: `App/ColophonApp.swift`, `App/Views/PlayerBarView.swift`, all views carrying per-view `.fontDesign(.serif)`
- Modify: `App/ColophonTests/AppStateTests.swift` (or a small SettingsTests) for the rate/skip plumbing

**Interfaces:**
- Produces: `@AppStorage("colophon.typeface") var typeface = "serif"` applied ONCE at the root (`.fontDesign(typeface == "serif" ? .serif : .default)` on the WindowGroup content; per-view serif modifiers REMOVED in the same commit — single source of truth); `colophon.defaultRate` applied in `PlaybackController.load` path via AppState (set `playback.rate` before `play()` on each new load; per-book overrides remain M2/CloudSync scope); `colophon.skipInterval` drives PlayerBarView's skip buttons (icon variants goforward.10/15/30/45) — NowPlayingUpdater's `preferredIntervals` gets the same value threaded through a `PlaybackController.skipInterval` property.
- Surfaces: macOS `Settings` scene (⌘,, Form with three controls); iOS/iPadOS gear toolbar button on ConnectionsView/LibrariesView presenting a sheet with the same `SettingsView`.

- [ ] Steps: failing plumbing tests (default rate lands on load; skip interval reaches controller) → implement + serif sweep → suites/builds → quick E2E: launch Mac app, ⌘, opens Settings; toggle to San Francisco → UI switches live (screenshot); back to serif; terminate → commit `feat(app): Settings scene with typeface, rate, and skip-interval preferences`.

---

### Task 10: Polish batch — background-flush protection, stale-state clear, small carry-forwards

**Files:**
- Modify: `App/AppState.swift` (`flushForBackground` wraps the flush in `UIApplication.shared.beginBackgroundTask`/`endBackgroundTask`, `#if os(iOS)`; macOS path unchanged), `App/Views/LibrariesView.swift` + `LibraryItemsView.swift` (reset `@State` arrays at the top of the `.task(id:)` body so a connection switch never flashes the previous connection's rows)
- Modify: `Packages/ABSKit/Tests/ABSRealtimeTests/ServerEventTests.swift` (add the two missing decode branches: `items_added` plural; progress with non-nil `episodeId`)

**Interfaces:** none new. Explicitly NOT done (documented in the commit): removing `pause()`'s internal fire-and-forget flush — it is load-bearing for remote-command pauses (lock screen) where no caller awaits `flushOnly()`; the redundant no-op on app-initiated paths is the accepted cost.

- [ ] Steps: tests where testable (decode branches; background-task assertion is build-verified + a note) → implement → suites/builds → commit `fix(app): background flush protection and connection-switch state hygiene`.

---

### Task 11: M1b wrap-up

**Files:** `README.md`; freeze note in `Packages/LibraryCache/Sources/LibraryCache/Schema.swift` (comment: v1 frozen as of M1b — future changes are v2+ migrations; remove/keep the DEBUG erase flag per comment guidance)

- [ ] README Status → M1b reality (OIDC sign-in, multi-connection with offline cached-first activation, Settings/typography, deletion reconciliation). Dev section gains the Dex/OIDC test user and `make test-app`.
- [ ] Full sweep: `make test && make test-app && make build-ios && make build-mac`; cold start (`server-down`, wipe `devserver/data`, `server-up`, `seed`) → contract suites (ABS + OIDC contract test) green from factory-fresh; password AND OIDC login both verified against the fresh stack.
- [ ] Commit `docs: M1b status`. NO tag (controller tags after the final whole-branch review).

---

## Self-review notes (performed at plan-writing time)

- **Coverage vs M1b scope (overview + M1a final-review mandates):** composite PKs+deletion (T1/T4 — BEFORE switch UI in T8 ✓), AppState harness (T3), batched progress (T1), logout→stopSocket (T8), switch playback policy (Global Constraints + T8 tests), try!→recovery (T1), contract-block refresh (this doc), ServerVersion suffixes (T2), background flush (T10), OIDC+Dex+spike (T5–T7), connections UX + offline first-run (T8), Settings+serif toggle (T9), refresh banner + alert titles (T4), silent-refresh fix (T4), items_added/episodeID decode tests (T10), entitlement bundle-id DRY (deferred — signing churn not worth it pre-TestFlight, recorded).
- **Known risks:** T5 networking (host.docker.internal) has an explicit NEEDS_CONTEXT path rather than a sudo attempt; T7's browser-sheet automation may fall back to contract-test + manual note (honestly labeled); ABS OIDC settings endpoint is discovered empirically with the payload recorded.
- **Type consistency:** `RealtimeSocketProtocol` introduced in T3 is adopted by SocketService without signature changes; `OIDCFlow.authenticate(browser:)` returns the existing `LoginResponse`; `deleteConnection` (T8) complements T1's store additions; settings keys match Global Constraints everywhere they appear.
