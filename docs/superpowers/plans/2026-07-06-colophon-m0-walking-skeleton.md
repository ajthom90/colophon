# Colophon M0 — Walking Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A thin end-to-end slice of Colophon: connect to an Audiobookshelf server with username/password, browse a library, and stream a multi-file audiobook with correct progress sync — on iPhone **and** Mac — plus the two M0 de-risking spikes (socket.io handshake, macOS grid performance).

**Architecture:** One XcodeGen-generated multiplatform app target (iOS + macOS for M0) that is a thin SwiftUI shell over two local Swift packages: `ABSKit` (HTTP transport, auth state machine, typed endpoints) and `PlayerEngine` (book timeline math, session-sync accounting, AVQueuePlayer wrapper, Now Playing integration). A Dockerized ABS server with seeded public-domain content provides deterministic dev/contract-test infrastructure.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing (`import Testing`), AVFoundation, MediaPlayer, XcodeGen, Docker (audiobookshelf 2.35.1), socket.io-client-swift (spike only).

## Global Constraints

- Deployment targets: **iOS 26.0, macOS 26.0** (spec: "OS 26+ only"). Build with Xcode 26.6 / 26.5 SDKs.
- Server support floor: **Audiobookshelf ≥ v2.26.0**; no legacy-token support. Dev server pins image `2.35.1`.
- Swift 6.2, default-MainActor app module, `@Observable` state. Packages compile with strict concurrency.
- Bundle ID `com.ajthom90.colophon` (single place: `project.yml`). Product/scheme name `Colophon`.
- App name in UI copy: **Colophon** (App Store listing later: "Colophon — for Audiobookshelf").
- Auth: `POST /login` **must send header `x-return-tokens: true`**; refresh via `POST /auth/refresh` with `x-refresh-token` header; **always overwrite the stored refresh token with the returned one**; refresh is single-flight; any 401 → refresh once → retry once → surface re-login.
- Playback URLs: prefer `GET /public/session/{sessionId}/track/{track.index}` (unauthenticated, session-scoped). Use the track's own `index` field, never the array position.
- Session sync: every 15 s while playing; `timeListened` is the **delta since last successful sync** (accumulate across failures, reset only on success).
- ATS: `NSAllowsArbitraryLoads = true` (self-hosted HTTP servers). macOS sandbox with `com.apple.security.network.client`.
- No GRDB/downloads/OIDC/socket integration in M0 (M1/M2 features). The socket.io work in M0 is a throwaway spike executable.
- Tests: Swift Testing framework. Contract tests against the Docker server run **only** when env `ABS_CONTRACT_URL` is set (never in default `swift test`).
- Commit after every green test cycle. Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## File Structure (end state of M0)

```
project.yml                          XcodeGen project definition (single source of truth)
Makefile                             gen / build / test / server shortcuts
.gitignore                           ignores generated .xcodeproj, devserver/data, DerivedData
App/
  ColophonApp.swift                  @main; owns AppState
  AppState.swift                     connection lifecycle + playback wiring
  Views/ConnectView.swift            server URL + credentials form
  Views/LibrariesView.swift          library picker
  Views/LibraryItemsView.swift       paged cover grid
  Views/PlayerBarView.swift          transport bar (play/pause/skip/scrub/rate)
  Views/PerfSpikeView.swift          DEBUG-only 10k-item grid (Task 14)
  Colophon.entitlements
Packages/ABSKit/
  Package.swift
  Sources/ABSKit/Transport.swift     Transport protocol + URLSessionTransport + HTTPResponse
  Sources/ABSKit/Models.swift        ServerStatus, LoginResponse, Library, ItemsPage,
                                     LibraryItemSummary, PlaybackSession, AudioTrack, Chapter
  Sources/ABSKit/TokenStore.swift    TokenPair, TokenStore protocol, InMemoryTokenStore,
                                     KeychainTokenStore
  Sources/ABSKit/AuthManager.swift   login/refresh state machine (actor)
  Sources/ABSKit/ABSClient.swift     typed endpoints, 401-retry-once
  Tests/ABSKitTests/Fixtures/*.json  hand-written server-shape fixtures
  Tests/ABSKitTests/*.swift
Packages/PlayerEngine/
  Package.swift
  Sources/PlayerEngine/BookTimeline.swift       global time ↔ (track, offset) math
  Sources/PlayerEngine/SessionSyncController.swift  15s cadence + delta accounting
  Sources/PlayerEngine/PlayerEngine.swift       AVQueuePlayer wrapper (@MainActor)
  Sources/PlayerEngine/NowPlayingUpdater.swift  MPNowPlayingInfoCenter/MPRemoteCommandCenter
  Tests/PlayerEngineTests/*.swift
Tools/SocketSpike/                   throwaway SPM executable (Task 13)
devserver/
  docker-compose.yml
  seed.sh                            init root user, download LibriVox book, create library, scan
  README.md
docs/superpowers/spikes/             spike outcome notes (Tasks 13–14)
```

**Interface contracts used across tasks** (defined once here; task "Interfaces" blocks repeat the parts they touch):

```swift
// ABSKit
public struct HTTPResponse: Sendable { public let statusCode: Int; public let data: Data; public let headers: [String: String] }
public protocol Transport: Sendable { func send(_ request: URLRequest) async throws -> HTTPResponse }

public struct TokenPair: Sendable, Equatable { public var accessToken: String; public var refreshToken: String? }
public protocol TokenStore: Sendable {
    func tokens(for connectionID: String) async -> TokenPair?
    func save(_ tokens: TokenPair, for connectionID: String) async
    func clear(for connectionID: String) async
}

public actor AuthManager {
    public init(baseURL: URL, connectionID: String, transport: Transport, store: TokenStore)
    public func login(username: String, password: String) async throws -> LoginResponse
    public func currentAccessToken() async throws -> String          // throws .notAuthenticated
    public func refreshAfterAuthFailure(staleToken: String) async throws -> String
    public func logout() async
}

public final class ABSClient: Sendable {
    public init(baseURL: URL, transport: Transport, auth: AuthManager)
    public static func status(baseURL: URL, transport: Transport) async throws -> ServerStatus  // unauthenticated
    public func libraries() async throws -> [Library]
    public func items(libraryID: String, limit: Int, page: Int) async throws -> ItemsPage
    public func startPlayback(itemID: String, deviceInfo: DeviceInfo) async throws -> PlaybackSession
    public func syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws
    public func closeSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws
    public func coverURL(itemID: String, width: Int, updatedAt: Int?) -> URL                    // unauthenticated
    public func publicTrackURL(sessionID: String, trackIndex: Int) -> URL
}

// PlayerEngine
public struct BookTimeline: Sendable {
    public struct Position: Equatable, Sendable { public let trackIndex: Int; public let offset: TimeInterval }
    public init(tracks: [AudioTrack])                 // tracks from PlaybackSession, sorted by startOffset
    public var totalDuration: TimeInterval { get }
    public func position(at globalTime: TimeInterval) -> Position
    public func globalTime(trackIndex: Int, offset: TimeInterval) -> TimeInterval
}

public struct SessionSyncController: Sendable {       // value type driven by PlayerEngine ticks
    public init(interval: TimeInterval = 15)
    public mutating func noteProgress(currentTime: TimeInterval, listenedDelta: TimeInterval, now: Date) -> SyncPayload?
    public mutating func didSync()                     // reset accumulated listened time
    public mutating func flush(currentTime: TimeInterval) -> SyncPayload?
}
public struct SyncPayload: Equatable, Sendable { public let currentTime: Double; public let timeListened: Double }
```

---

### Task 0: File the CarPlay entitlement application (manual, user-performed)

**Files:** none (external action; record outcome in `docs/superpowers/carplay-entitlement.md`)

**Interfaces:** none. Nothing in M0–M1 depends on approval; the CarPlay scene lands in M2. Filing now because approval takes days-to-weeks with no SLA.

- [ ] **Step 1: Submit the request**

At https://developer.apple.com/contact/carplay/ (signed into the Apple Developer account that will ship Colophon), request the **CarPlay Audio App** entitlement (`com.apple.developer.carplay-audio`) for bundle ID `com.ajthom90.colophon`. Suggested description: "Colophon is a native audiobook and podcast player for user-hosted Audiobookshelf servers. CarPlay support provides browse (continue-listening, library, downloads) and now-playing control for long-form spoken audio while driving."

- [ ] **Step 2: Record the submission**

Create `docs/superpowers/carplay-entitlement.md` containing the submission date, bundle ID, and status `submitted`. Commit:

```bash
git add docs/superpowers/carplay-entitlement.md
git commit -m "chore: record CarPlay entitlement application"
```

---

### Task 1: Repo scaffold + XcodeGen project that builds empty app on iOS and macOS

**Files:**
- Create: `.gitignore`, `project.yml`, `Makefile`, `App/ColophonApp.swift`, `App/Colophon.entitlements`
- Create (placeholder packages so `project.yml` resolves): `Packages/ABSKit/Package.swift`, `Packages/ABSKit/Sources/ABSKit/ABSKit.swift`, `Packages/PlayerEngine/Package.swift`, `Packages/PlayerEngine/Sources/PlayerEngine/PlayerEngine.swift`

**Interfaces:**
- Produces: buildable `Colophon.xcodeproj` via `make gen`; `make build-ios` / `make build-mac` green. All later tasks assume these commands work.

- [ ] **Step 1: Install XcodeGen if missing**

Run: `which xcodegen || brew install xcodegen`
Expected: path to xcodegen binary.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
Colophon.xcodeproj/
DerivedData/
.DS_Store
devserver/data/
xcuserdata/
.build/
```

- [ ] **Step 3: Write placeholder packages**

`Packages/ABSKit/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ABSKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "ABSKit", targets: ["ABSKit"])],
    targets: [
        .target(name: "ABSKit"),
        .testTarget(name: "ABSKitTests", dependencies: ["ABSKit"], resources: [.copy("Fixtures")]),
    ]
)
```

`Packages/ABSKit/Sources/ABSKit/ABSKit.swift`:

```swift
public enum ABSKitInfo { public static let version = "0.1.0" }
```

`Packages/PlayerEngine/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlayerEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PlayerEngine", targets: ["PlayerEngine"])],
    dependencies: [.package(path: "../ABSKit")],
    targets: [
        .target(name: "PlayerEngine", dependencies: ["ABSKit"]),
        .testTarget(name: "PlayerEngineTests", dependencies: ["PlayerEngine"]),
    ]
)
```

`Packages/PlayerEngine/Sources/PlayerEngine/PlayerEngine.swift`:

```swift
public enum PlayerEngineInfo { public static let version = "0.1.0" }
```

(Create `Packages/ABSKit/Tests/ABSKitTests/Fixtures/.gitkeep` and a trivial passing test file in each test target so `swift test` runs: `@Test func packageLoads() { #expect(true) }` with `import Testing`.)

- [ ] **Step 4: Write `project.yml`**

```yaml
name: Colophon
options:
  bundleIdPrefix: com.ajthom90
  deploymentTarget:
    iOS: "26.0"
    macOS: "26.0"
  createIntermediateGroups: true
packages:
  ABSKit:
    path: Packages/ABSKit
  PlayerEngine:
    path: Packages/PlayerEngine
targets:
  Colophon:
    type: application
    supportedDestinations: [iOS, macOS]
    sources: [App]
    dependencies:
      - package: ABSKit
      - package: PlayerEngine
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ajthom90.colophon
        PRODUCT_NAME: Colophon
        SWIFT_VERSION: "6.2"
        SWIFT_STRICT_CONCURRENCY: complete
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
        ENABLE_USER_SCRIPT_SANDBOXING: true
        CODE_SIGN_ENTITLEMENTS: App/Colophon.entitlements
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: 1
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: Colophon
        UILaunchScreen: {}
        UIBackgroundModes: [audio]
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        NSLocalNetworkUsageDescription: "Colophon connects to your Audiobookshelf server, which may be on your local network."
schemes:
  Colophon:
    build:
      targets: { Colophon: all }
```

- [ ] **Step 5: Write `App/Colophon.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 6: Write `App/ColophonApp.swift`**

```swift
import SwiftUI

@main
struct ColophonApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Colophon")
                .font(.largeTitle)
                .fontDesign(.serif)
        }
    }
}
```

- [ ] **Step 7: Write `Makefile`**

```makefile
SIM ?= iPhone 17

gen:
	xcodegen generate

build-ios: gen
	xcodebuild -project Colophon.xcodeproj -scheme Colophon \
	  -destination 'platform=iOS Simulator,name=$(SIM)' build | tail -5

build-mac: gen
	xcodebuild -project Colophon.xcodeproj -scheme Colophon \
	  -destination 'platform=macOS' build | tail -5

test:
	cd Packages/ABSKit && swift test
	cd Packages/PlayerEngine && swift test

server-up:
	docker compose -f devserver/docker-compose.yml up -d

server-down:
	docker compose -f devserver/docker-compose.yml down

seed:
	bash devserver/seed.sh
```

(If no `iPhone 17` simulator exists, list with `xcrun simctl list devices available` and pass `SIM="<name>"`.)

- [ ] **Step 8: Verify builds and tests**

Run: `make build-ios && make build-mac && make test`
Expected: `BUILD SUCCEEDED` twice; both package test suites pass (1 trivial test each).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: scaffold Colophon multiplatform project (XcodeGen, iOS+macOS, SPM packages)"
```

---

### Task 2: Dockerized dev server with seeded audiobook

**Files:**
- Create: `devserver/docker-compose.yml`, `devserver/seed.sh`, `devserver/README.md`

**Interfaces:**
- Produces: ABS server at `http://localhost:13378`, root credentials `root` / `colophon-dev`, one book library ("Books") containing LibriVox's *The Art of War* (multi-file MP3 — exercises multi-track timeline math). Contract tests (Task 9) and all manual E2E checks use it.

- [ ] **Step 1: Write `devserver/docker-compose.yml`**

```yaml
services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:2.35.1
    container_name: colophon-abs
    ports:
      - "13378:80"
    volumes:
      - ./data/audiobooks:/audiobooks
      - ./data/config:/config
      - ./data/metadata:/metadata
```

- [ ] **Step 2: Write `devserver/seed.sh`**

```bash
#!/usr/bin/env bash
# Seeds the dev ABS server: root user, one library, one public-domain multi-file audiobook.
set -euo pipefail
BASE="http://localhost:13378"
USER="root"
PASS="colophon-dev"
BOOK_DIR="$(dirname "$0")/data/audiobooks/Sun Tzu/The Art of War"

echo "→ waiting for server"
until curl -fsS "$BASE/status" >/dev/null 2>&1; do sleep 1; done

IS_INIT=$(curl -fsS "$BASE/status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["isInit"])')
if [ "$IS_INIT" = "False" ] || [ "$IS_INIT" = "false" ]; then
  echo "→ initializing root user"
  curl -fsS -X POST "$BASE/init" -H 'Content-Type: application/json' \
    -d "{\"newRoot\":{\"username\":\"$USER\",\"password\":\"$PASS\"}}" >/dev/null
fi

if [ ! -d "$BOOK_DIR" ]; then
  echo "→ downloading The Art of War (LibriVox, public domain)"
  mkdir -p "$BOOK_DIR"
  TMP=$(mktemp -d)
  curl -fL "https://archive.org/download/art_of_war_librivox/art_of_war_librivox_64kb_mp3.zip" -o "$TMP/book.zip"
  unzip -q "$TMP/book.zip" -d "$BOOK_DIR"
  rm -rf "$TMP"
fi

echo "→ logging in"
TOKEN=$(curl -fsS -X POST "$BASE/login" -H 'Content-Type: application/json' -H 'x-return-tokens: true' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"]["accessToken"])')

LIB_COUNT=$(curl -fsS "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["libraries"]))')
if [ "$LIB_COUNT" = "0" ]; then
  echo "→ creating Books library"
  curl -fsS -X POST "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name":"Books","mediaType":"book","folders":[{"fullPath":"/audiobooks"}],"provider":"google"}' >/dev/null
fi

LIB_ID=$(curl -fsS "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["libraries"][0]["id"])')
echo "→ scanning library $LIB_ID"
curl -fsS -X POST "$BASE/api/libraries/$LIB_ID/scan" -H "Authorization: Bearer $TOKEN" >/dev/null || true
echo "✓ seeded. Web UI: $BASE ($USER / $PASS)"
```

- [ ] **Step 3: Write `devserver/README.md`**

```markdown
# Colophon dev server

`make server-up && make seed` → Audiobookshelf 2.35.1 at http://localhost:13378
(root / colophon-dev) with one library ("Books") containing a multi-file
LibriVox audiobook. `make server-down` stops it; delete `devserver/data/` for
a factory reset. Contract tests use `ABS_CONTRACT_URL=http://localhost:13378`.
Simulators reach it via localhost; a physical device needs your Mac's LAN IP.
```

- [ ] **Step 4: Verify**

Run: `chmod +x devserver/seed.sh && make server-up && make seed && curl -s http://localhost:13378/status`
Expected: seed script completes; `/status` JSON shows `"isInit":true` and `"serverVersion":"2.35.1"`. Open http://localhost:13378, log in, confirm *The Art of War* appears with multiple tracks (wait ~30s for scan if needed).

- [ ] **Step 5: Commit**

```bash
git add devserver Makefile
git commit -m "feat: add dockerized ABS dev server with seeded LibriVox book"
```

---

### Task 3: ABSKit models decode server JSON (fixtures)

**Files:**
- Create: `Packages/ABSKit/Sources/ABSKit/Models.swift`
- Create: `Packages/ABSKit/Tests/ABSKitTests/Fixtures/status.json`, `login.json`, `libraries.json`, `items_page.json`, `playback_session.json`
- Create: `Packages/ABSKit/Tests/ABSKitTests/ModelDecodingTests.swift`
- Delete: placeholder test from Task 1.

**Interfaces:**
- Produces (used by every later task): `ServerStatus{isInit, serverVersion, authMethods:[String]?}`, `LoginResponse{user: User}`, `User{id, username, accessToken:String?, refreshToken:String?}`, `Library{id, name, mediaType}`, `ItemsPage{results:[LibraryItemSummary], total, limit, page}`, `LibraryItemSummary{id, updatedAt:Int?, media:MinifiedMedia{duration:Double?, metadata:MinifiedMetadata{title:String?, authorName:String?}}}`, `PlaybackSession{id, libraryItemId, displayTitle:String?, displayAuthor:String?, duration:Double, startTime:Double, playMethod:Int, audioTracks:[AudioTrack], chapters:[Chapter]}`, `AudioTrack{index:Int, startOffset:Double, duration:Double, title:String?, contentUrl:String?, mimeType:String?}`, `Chapter{id:Int, start:Double, end:Double, title:String?}`, `DeviceInfo{deviceId, clientName, clientVersion, manufacturer, model}`. All `Decodable` (DeviceInfo `Encodable`), tolerant of unknown/absent fields.

- [ ] **Step 1: Write fixtures** (hand-authored to the server's "old JSON" shapes; keep values realistic)

`Fixtures/status.json`:

```json
{"app":"audiobookshelf","serverVersion":"2.35.1","isInit":true,"language":"en-us","authMethods":["local"],"authFormData":{"authLoginCustomMessage":null}}
```

`Fixtures/login.json`:

```json
{"user":{"id":"usr_abc123","username":"root","type":"root","accessToken":"eyJ.access.1","refreshToken":"eyJ.refresh.1","token":"legacy-token","mediaProgress":[],"bookmarks":[],"permissions":{"download":true,"update":true}},"userDefaultLibraryId":"lib_1","serverSettings":{"version":"2.35.1"},"Source":"docker"}
```

`Fixtures/libraries.json`:

```json
{"libraries":[{"id":"lib_1","name":"Books","folders":[{"id":"fol_1","fullPath":"/audiobooks"}],"displayOrder":1,"icon":"audiobookshelf","mediaType":"book","provider":"google","settings":{"coverAspectRatio":1},"createdAt":1751000000000,"lastUpdate":1751000000000}]}
```

`Fixtures/items_page.json`:

```json
{"results":[{"id":"li_1","ino":"9771","libraryId":"lib_1","mediaType":"book","addedAt":1751000000000,"updatedAt":1751060000000,"isMissing":false,"numFiles":8,"media":{"id":"book_1","numTracks":7,"numChapters":7,"duration":4980.5,"size":45000000,"metadata":{"title":"The Art of War","titleIgnorePrefix":"Art of War","authorName":"Sun Tzu","narratorName":"Moira Fogarty","seriesName":""}}}],"total":1,"limit":50,"page":0,"sortBy":"media.metadata.title","sortDesc":false,"mediaType":"book","minified":true,"offset":0}
```

`Fixtures/playback_session.json`:

```json
{"id":"ses_xyz789","userId":"usr_abc123","libraryId":"lib_1","libraryItemId":"li_1","episodeId":null,"mediaType":"book","displayTitle":"The Art of War","displayAuthor":"Sun Tzu","coverPath":"/metadata/items/li_1/cover.jpg","duration":4980.5,"playMethod":0,"mediaPlayer":"AVPlayer","serverVersion":"2.35.1","date":"2026-07-06","dayOfWeek":"Monday","timeListening":0,"startTime":125.0,"currentTime":125.0,"startedAt":1751790000000,"updatedAt":1751790000000,"chapters":[{"id":0,"start":0,"end":600.2,"title":"Section 1"},{"id":1,"start":600.2,"end":1250.9,"title":"Section 2"}],"audioTracks":[{"index":1,"startOffset":0,"duration":600.2,"title":"artofwar_01.mp3","contentUrl":"/api/items/li_1/file/9772","mimeType":"audio/mpeg","metadata":{"filename":"artofwar_01.mp3","ext":".mp3","size":4800000}},{"index":2,"startOffset":600.2,"duration":650.7,"title":"artofwar_02.mp3","contentUrl":"/api/items/li_1/file/9773","mimeType":"audio/mpeg","metadata":{"filename":"artofwar_02.mp3","ext":".mp3","size":5200000}}]}
```

- [ ] **Step 2: Write the failing tests** — `Tests/ABSKitTests/ModelDecodingTests.swift`

```swift
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
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd Packages/ABSKit && swift test`
Expected: FAIL — types not defined.

- [ ] **Step 4: Write `Sources/ABSKit/Models.swift`**

```swift
import Foundation

public struct ServerStatus: Decodable, Sendable {
    public let isInit: Bool
    public let serverVersion: String?
    public let authMethods: [String]?
}

public struct LoginResponse: Decodable, Sendable {
    public let user: User
    public let userDefaultLibraryId: String?
}

public struct User: Decodable, Sendable {
    public let id: String
    public let username: String
    public let accessToken: String?
    public let refreshToken: String?
}

public struct LibrariesResponse: Decodable, Sendable { public let libraries: [Library] }

public struct Library: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let mediaType: String
    public let icon: String?
    public let displayOrder: Int?
}

public struct ItemsPage: Decodable, Sendable {
    public let results: [LibraryItemSummary]
    public let total: Int
    public let limit: Int
    public let page: Int
}

public struct LibraryItemSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let updatedAt: Int?
    public let media: MinifiedMedia
}

public struct MinifiedMedia: Decodable, Sendable, Hashable {
    public let duration: Double?
    public let metadata: MinifiedMetadata
}

public struct MinifiedMetadata: Decodable, Sendable, Hashable {
    public let title: String?
    public let authorName: String?
}

public struct PlaybackSession: Decodable, Sendable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let displayTitle: String?
    public let displayAuthor: String?
    public let duration: Double
    public let startTime: Double
    public let currentTime: Double?
    public let playMethod: Int
    public let audioTracks: [AudioTrack]
    public let chapters: [Chapter]
}

public struct AudioTrack: Decodable, Sendable {
    public let index: Int
    public let startOffset: Double
    public let duration: Double
    public let title: String?
    public let contentUrl: String?
    public let mimeType: String?
}

public struct Chapter: Decodable, Sendable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String?
}

public struct DeviceInfo: Encodable, Sendable {
    public let deviceId: String
    public let clientName: String
    public let clientVersion: String
    public let manufacturer: String
    public let model: String
    public init(deviceId: String, clientName: String = "Colophon",
                clientVersion: String, manufacturer: String = "Apple", model: String) {
        self.deviceId = deviceId; self.clientName = clientName
        self.clientVersion = clientVersion; self.manufacturer = manufacturer; self.model = model
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Packages/ABSKit && swift test`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/ABSKit
git commit -m "feat(ABSKit): server DTOs with tolerant decoding + fixtures"
```

---

### Task 4: Transport abstraction + unauthenticated endpoints (status, login)

**Files:**
- Create: `Packages/ABSKit/Sources/ABSKit/Transport.swift`
- Create: `Packages/ABSKit/Tests/ABSKitTests/MockTransport.swift`
- Create: `Packages/ABSKit/Tests/ABSKitTests/StatusLoginTests.swift`

**Interfaces:**
- Produces: `Transport` protocol + `URLSessionTransport` + `HTTPResponse` (contract block above); free functions used by AuthManager/ABSClient: `ABSAPI.statusRequest(baseURL:)`, `ABSAPI.loginRequest(baseURL:username:password:)` returning `URLRequest`; `ABSError` enum: `.http(status: Int)`, `.notAuthenticated`, `.reauthRequired`, `.invalidResponse`.
- Test helper `MockTransport`: `actor MockTransport: Transport` with `enqueue(status:json:)` FIFO and `recorded: [URLRequest]`.

- [ ] **Step 1: Write failing tests** — `Tests/ABSKitTests/StatusLoginTests.swift`

```swift
import Foundation
import Testing
@testable import ABSKit

@Suite struct StatusLoginTests {
    let base = URL(string: "http://abs.test:13378")!

    @Test func statusRequestShape() {
        let req = ABSAPI.statusRequest(baseURL: base)
        #expect(req.url?.absoluteString == "http://abs.test:13378/status")
        #expect(req.httpMethod == "GET")
    }

    @Test func loginRequestSendsReturnTokensHeaderAndBody() throws {
        let req = ABSAPI.loginRequest(baseURL: base, username: "root", password: "pw")
        #expect(req.url?.absoluteString == "http://abs.test:13378/login")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]
        #expect(body == ["username": "root", "password": "pw"])
    }

    @Test func non2xxBecomesHTTPError() async throws {
        let mock = MockTransport()
        await mock.enqueue(status: 401, json: #"{"error":"Unauthorized"}"#)
        await #expect(throws: ABSError.http(status: 401)) {
            _ = try await ABSAPI.send(ABSAPI.statusRequest(baseURL: base), as: ServerStatus.self, via: mock)
        }
    }

    @Test func decodesThroughTransport() async throws {
        let mock = MockTransport()
        await mock.enqueue(status: 200, json: #"{"isInit":true,"serverVersion":"2.35.1"}"#)
        let s = try await ABSAPI.send(ABSAPI.statusRequest(baseURL: base), as: ServerStatus.self, via: mock)
        #expect(s.serverVersion == "2.35.1")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/ABSKit && swift test --filter StatusLoginTests`
Expected: FAIL — `ABSAPI`/`MockTransport` not defined.

- [ ] **Step 3: Implement `Sources/ABSKit/Transport.swift`**

```swift
import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]
    public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode; self.data = data; self.headers = headers
    }
}

public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: Transport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ABSError.invalidResponse }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPResponse(statusCode: http.statusCode, data: data, headers: headers)
    }
}

public enum ABSError: Error, Equatable {
    case http(status: Int)
    case notAuthenticated
    case reauthRequired
    case invalidResponse
}

public enum ABSAPI {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    public static func statusRequest(baseURL: URL) -> URLRequest {
        URLRequest(url: baseURL.appending(path: "status"))
    }

    public static func loginRequest(baseURL: URL, username: String, password: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: "login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-return-tokens")
        req.httpBody = try? encoder.encode(["username": username, "password": password])
        return req
    }

    public static func send<T: Decodable>(_ request: URLRequest, as type: T.Type, via transport: Transport) async throws -> T {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode) }
        return try decoder.decode(T.self, from: response.data)
    }

    public static func sendExpectingSuccess(_ request: URLRequest, via transport: Transport) async throws {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode) }
    }
}
```

- [ ] **Step 4: Implement test helper `Tests/ABSKitTests/MockTransport.swift`**

```swift
import Foundation
@testable import ABSKit

actor MockTransport: Transport {
    private var queue: [HTTPResponse] = []
    private(set) var recorded: [URLRequest] = []

    func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        queue.append(HTTPResponse(statusCode: status, data: Data(json.utf8), headers: headers))
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recorded.append(request)
        guard !queue.isEmpty else { throw ABSError.invalidResponse }
        return queue.removeFirst()
    }

    func requestCount() -> Int { recorded.count }
}
```

- [ ] **Step 5: Run tests, expect pass; commit**

Run: `cd Packages/ABSKit && swift test`
Expected: PASS.

```bash
git add Packages/ABSKit
git commit -m "feat(ABSKit): Transport abstraction, status/login requests, error model"
```

---

### Task 5: TokenStore (protocol, in-memory, Keychain)

**Files:**
- Create: `Packages/ABSKit/Sources/ABSKit/TokenStore.swift`
- Create: `Packages/ABSKit/Tests/ABSKitTests/TokenStoreTests.swift`

**Interfaces:**
- Produces: `TokenPair`, `TokenStore`, `InMemoryTokenStore` (tests + previews), `KeychainTokenStore` (app; `kSecAttrAccessibleAfterFirstUnlock`, service `"com.ajthom90.colophon.tokens"`). Keychain implementation is verified manually inside the app (Task 12); unit tests cover the protocol via `InMemoryTokenStore` (SPM test hosts have no reliable Keychain).

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import ABSKit

@Suite struct TokenStoreTests {
    @Test func roundTripsAndClears() async {
        let store = InMemoryTokenStore()
        #expect(await store.tokens(for: "c1") == nil)
        await store.save(TokenPair(accessToken: "a1", refreshToken: "r1"), for: "c1")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "a1", refreshToken: "r1"))
        await store.save(TokenPair(accessToken: "a2", refreshToken: "r2"), for: "c1")
        #expect(await store.tokens(for: "c1")?.accessToken == "a2")
        await store.clear(for: "c1")
        #expect(await store.tokens(for: "c1") == nil)
    }

    @Test func isolatesConnections() async {
        let store = InMemoryTokenStore()
        await store.save(TokenPair(accessToken: "a", refreshToken: nil), for: "c1")
        #expect(await store.tokens(for: "c2") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** (`swift test --filter TokenStoreTests` → FAIL)

- [ ] **Step 3: Implement `Sources/ABSKit/TokenStore.swift`**

```swift
import Foundation
#if canImport(Security)
import Security
#endif

public struct TokenPair: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public init(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
    }
}

public protocol TokenStore: Sendable {
    func tokens(for connectionID: String) async -> TokenPair?
    func save(_ tokens: TokenPair, for connectionID: String) async
    func clear(for connectionID: String) async
}

public actor InMemoryTokenStore: TokenStore {
    private var storage: [String: TokenPair] = [:]
    public init() {}
    public func tokens(for connectionID: String) -> TokenPair? { storage[connectionID] }
    public func save(_ tokens: TokenPair, for connectionID: String) { storage[connectionID] = tokens }
    public func clear(for connectionID: String) { storage[connectionID] = nil }
}

/// Device-local by design: refresh tokens rotate on every use, so they must never
/// sync between devices (kSecAttrSynchronizable stays false).
public actor KeychainTokenStore: TokenStore {
    private let service = "com.ajthom90.colophon.tokens"
    public init() {}

    public func tokens(for connectionID: String) -> TokenPair? {
        var query = baseQuery(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TokenPair.self, from: data)
    }

    public func save(_ tokens: TokenPair, for connectionID: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        var query = baseQuery(connectionID)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attrs) { _, new in new }
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    public func clear(for connectionID: String) {
        SecItemDelete(baseQuery(connectionID) as CFDictionary)
    }

    private func baseQuery(_ connectionID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: connectionID]
    }
}
```

- [ ] **Step 4: Run tests, expect pass; commit**

```bash
git add Packages/ABSKit
git commit -m "feat(ABSKit): TokenStore protocol with in-memory and Keychain implementations"
```

---

### Task 6: AuthManager — login, single-flight refresh, rotation rules

**Files:**
- Create: `Packages/ABSKit/Sources/ABSKit/AuthManager.swift`
- Create: `Packages/ABSKit/Tests/ABSKitTests/AuthManagerTests.swift`

**Interfaces:**
- Consumes: `Transport`, `TokenStore`, `ABSAPI.loginRequest`, models from Task 3.
- Produces (exact contract Task 7/12 rely on):
  - `login(username:password:) async throws -> LoginResponse` — stores `TokenPair` on success; throws `ABSError.http(status:)` on bad credentials.
  - `currentAccessToken() async throws -> String` — throws `ABSError.notAuthenticated` when no tokens stored.
  - `refreshAfterAuthFailure(staleToken:) async throws -> String` — if the stored access token already differs from `staleToken`, returns it (another caller refreshed); otherwise POSTs `/auth/refresh` with `x-refresh-token`, stores new pair (keeping the old refresh token if the response omits one), returns the new access token. Concurrent callers share one in-flight refresh (single-flight). A 401 from refresh throws `ABSError.reauthRequired` and clears tokens.
  - `logout() async` — best-effort `POST /logout` with `x-refresh-token`, then clears the store.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
@testable import ABSKit

@Suite struct AuthManagerTests {
    let base = URL(string: "http://abs.test:13378")!

    private func makeSUT() async -> (AuthManager, MockTransport, InMemoryTokenStore) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        return (auth, transport, store)
    }

    private let loginJSON = #"{"user":{"id":"u1","username":"root","accessToken":"acc1","refreshToken":"ref1"}}"#

    @Test func loginStoresTokenPair() async throws {
        let (auth, transport, store) = await makeSUT()
        await transport.enqueue(status: 200, json: loginJSON)
        _ = try await auth.login(username: "root", password: "pw")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "acc1", refreshToken: "ref1"))
        #expect(try await auth.currentAccessToken() == "acc1")
    }

    @Test func currentTokenThrowsWhenLoggedOut() async {
        let (auth, _, _) = await makeSUT()
        await #expect(throws: ABSError.notAuthenticated) { _ = try await auth.currentAccessToken() }
    }

    @Test func refreshSendsHeaderAndOverwritesRotatedPair() async throws {
        let (auth, transport, store) = await makeSUT()
        await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"root","accessToken":"acc2","refreshToken":"ref2"}}"#)
        let newToken = try await auth.refreshAfterAuthFailure(staleToken: "acc1")
        #expect(newToken == "acc2")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "acc2", refreshToken: "ref2"))
        let req = await transport.recorded.last
        #expect(req?.url?.absoluteString == "http://abs.test:13378/auth/refresh")
        #expect(req?.value(forHTTPHeaderField: "x-refresh-token") == "ref1")
    }

    @Test func refreshKeepsOldRefreshTokenWhenResponseOmitsIt() async throws {
        let (auth, transport, store) = await makeSUT()
        await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"root","accessToken":"acc2"}}"#)
        _ = try await auth.refreshAfterAuthFailure(staleToken: "acc1")
        #expect(await store.tokens(for: "c1") == TokenPair(accessToken: "acc2", refreshToken: "ref1"))
    }

    @Test func staleCallerGetsAlreadyRefreshedTokenWithoutSecondRequest() async throws {
        let (auth, transport, store) = await makeSUT()
        await store.save(TokenPair(accessToken: "acc2", refreshToken: "ref2"), for: "c1")
        let token = try await auth.refreshAfterAuthFailure(staleToken: "acc1")  // caller holds old token
        #expect(token == "acc2")
        #expect(await transport.requestCount() == 0)
    }

    @Test func concurrentRefreshesCollapseToOneRequest() async throws {
        let (auth, transport, store) = await makeSUT()
        await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"root","accessToken":"acc2","refreshToken":"ref2"}}"#)
        async let a = auth.refreshAfterAuthFailure(staleToken: "acc1")
        async let b = auth.refreshAfterAuthFailure(staleToken: "acc1")
        let (ta, tb) = try await (a, b)
        #expect(ta == "acc2" && tb == "acc2")
        #expect(await transport.requestCount() == 1)
    }

    @Test func refresh401ClearsTokensAndSignalsReauth() async {
        let (auth, transport, store) = await makeSUT()
        await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        await transport.enqueue(status: 401, json: #"{"error":"Unauthorized"}"#)
        await #expect(throws: ABSError.reauthRequired) {
            _ = try await auth.refreshAfterAuthFailure(staleToken: "acc1")
        }
        #expect(await store.tokens(for: "c1") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** (`swift test --filter AuthManagerTests` → FAIL)

- [ ] **Step 3: Implement `Sources/ABSKit/AuthManager.swift`**

```swift
import Foundation

public actor AuthManager {
    private let baseURL: URL
    private let connectionID: String
    private let transport: Transport
    private let store: TokenStore
    private var inFlightRefresh: Task<String, Error>?

    public init(baseURL: URL, connectionID: String, transport: Transport, store: TokenStore) {
        self.baseURL = baseURL
        self.connectionID = connectionID
        self.transport = transport
        self.store = store
    }

    public func login(username: String, password: String) async throws -> LoginResponse {
        let response = try await ABSAPI.send(
            ABSAPI.loginRequest(baseURL: baseURL, username: username, password: password),
            as: LoginResponse.self, via: transport)
        guard let access = response.user.accessToken else { throw ABSError.invalidResponse }
        await store.save(TokenPair(accessToken: access, refreshToken: response.user.refreshToken),
                         for: connectionID)
        return response
    }

    public func currentAccessToken() async throws -> String {
        guard let pair = await store.tokens(for: connectionID) else { throw ABSError.notAuthenticated }
        return pair.accessToken
    }

    public func refreshAfterAuthFailure(staleToken: String) async throws -> String {
        // Someone already refreshed while we were failing — use theirs.
        if let current = await store.tokens(for: connectionID), current.accessToken != staleToken {
            return current.accessToken
        }
        if let existing = inFlightRefresh { return try await existing.value }

        let task = Task<String, Error> { [baseURL, transport, store, connectionID] in
            guard let pair = await store.tokens(for: connectionID),
                  let refreshToken = pair.refreshToken else { throw ABSError.reauthRequired }
            var req = URLRequest(url: baseURL.appending(path: "auth/refresh"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
            do {
                let response = try await ABSAPI.send(req, as: LoginResponse.self, via: transport)
                guard let access = response.user.accessToken else { throw ABSError.invalidResponse }
                // Server rotates the refresh token; keep the old one only if none returned.
                let newPair = TokenPair(accessToken: access,
                                        refreshToken: response.user.refreshToken ?? refreshToken)
                await store.save(newPair, for: connectionID)
                return access
            } catch ABSError.http(status: 401) {
                await store.clear(for: connectionID)
                throw ABSError.reauthRequired
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    public func logout() async {
        if let pair = await store.tokens(for: connectionID), let refresh = pair.refreshToken {
            var req = URLRequest(url: baseURL.appending(path: "logout"))
            req.httpMethod = "POST"
            req.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            _ = try? await transport.send(req)
        }
        await store.clear(for: connectionID)
    }
}
```

- [ ] **Step 4: Run tests, expect pass; commit**

```bash
git add Packages/ABSKit
git commit -m "feat(ABSKit): AuthManager with single-flight refresh and rotation-safe storage"
```

---

### Task 7: ABSClient — authorized requests, libraries, items

**Files:**
- Create: `Packages/ABSKit/Sources/ABSKit/ABSClient.swift`
- Create: `Packages/ABSKit/Tests/ABSKitTests/ABSClientTests.swift`

**Interfaces:**
- Consumes: `AuthManager` (Task 6), `Transport`, models.
- Produces: `ABSClient` per the contract block (constructor + `libraries()`, `items(libraryID:limit:page:)`, `coverURL(itemID:width:updatedAt:)`), plus internal `authorizedSend<T>(_:as:)` implementing: Bearer header from `auth.currentAccessToken()` → on `.http(401)` → `refreshAfterAuthFailure` → retry **once** with the new token → propagate second failure.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
@testable import ABSKit

@Suite struct ABSClientTests {
    let base = URL(string: "http://abs.test:13378")!

    private func makeSUT() async -> (ABSClient, MockTransport, InMemoryTokenStore) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        return (ABSClient(baseURL: base, transport: transport, auth: auth), transport, store)
    }

    @Test func librariesSendsBearerAndDecodes() async throws {
        let (client, transport, _) = await makeSUT()
        await transport.enqueue(status: 200, json: #"{"libraries":[{"id":"lib_1","name":"Books","mediaType":"book"}]}"#)
        let libs = try await client.libraries()
        #expect(libs.map(\.id) == ["lib_1"])
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/libraries")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer acc1")
    }

    @Test func itemsBuildsPagedMinifiedQuery() async throws {
        let (client, transport, _) = await makeSUT()
        await transport.enqueue(status: 200, json: #"{"results":[],"total":0,"limit":50,"page":2}"#)
        _ = try await client.items(libraryID: "lib_1", limit: 50, page: 2)
        let url = await transport.recorded.first?.url
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        #expect(comps.path == "/api/libraries/lib_1/items")
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(q == ["limit": "50", "page": "2", "minified": "1", "sort": "media.metadata.title"])
    }

    @Test func retriesOnceAfter401ThenSucceeds() async throws {
        let (client, transport, _) = await makeSUT()
        await transport.enqueue(status: 401, json: #"{"error":"Unauthorized"}"#)                        // original call
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"r","accessToken":"acc2","refreshToken":"ref2"}}"#) // refresh
        await transport.enqueue(status: 200, json: #"{"libraries":[]}"#)                                  // retry
        _ = try await client.libraries()
        #expect(await transport.requestCount() == 3)
        let retry = await transport.recorded.last
        #expect(retry?.value(forHTTPHeaderField: "Authorization") == "Bearer acc2")
    }

    @Test func secondConsecutive401Propagates() async throws {
        let (client, transport, _) = await makeSUT()
        await transport.enqueue(status: 401, json: "{}")
        await transport.enqueue(status: 200, json: #"{"user":{"id":"u1","username":"r","accessToken":"acc2","refreshToken":"ref2"}}"#)
        await transport.enqueue(status: 401, json: "{}")
        await #expect(throws: ABSError.http(status: 401)) { _ = try await client.libraries() }
    }

    @Test func coverURLIsUnauthenticatedAndTimestamped() async {
        let (client, _, _) = await makeSUT()
        let url = client.coverURL(itemID: "li_1", width: 400, updatedAt: 1751060000000)
        #expect(url.absoluteString == "http://abs.test:13378/api/items/li_1/cover?width=400&ts=1751060000000")
    }
}
```

- [ ] **Step 2: Run to verify failure** (`swift test --filter ABSClientTests` → FAIL)

- [ ] **Step 3: Implement `Sources/ABSKit/ABSClient.swift`**

```swift
import Foundation

public final class ABSClient: Sendable {
    let baseURL: URL
    let transport: Transport
    let auth: AuthManager

    public init(baseURL: URL, transport: Transport, auth: AuthManager) {
        self.baseURL = baseURL; self.transport = transport; self.auth = auth
    }

    public static func status(baseURL: URL, transport: Transport) async throws -> ServerStatus {
        try await ABSAPI.send(ABSAPI.statusRequest(baseURL: baseURL), as: ServerStatus.self, via: transport)
    }

    public func libraries() async throws -> [Library] {
        try await authorizedSend(get("api/libraries"), as: LibrariesResponse.self).libraries
    }

    public func items(libraryID: String, limit: Int, page: Int) async throws -> ItemsPage {
        var comps = URLComponents(url: baseURL.appending(path: "api/libraries/\(libraryID)/items"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "limit", value: String(limit)),
            .init(name: "page", value: String(page)),
            .init(name: "minified", value: "1"),
            .init(name: "sort", value: "media.metadata.title"),
        ]
        return try await authorizedSend(URLRequest(url: comps.url!), as: ItemsPage.self)
    }

    public func coverURL(itemID: String, width: Int, updatedAt: Int?) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: "api/items/\(itemID)/cover"),
                                  resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [.init(name: "width", value: String(width))]
        if let updatedAt { query.append(.init(name: "ts", value: String(updatedAt))) }
        comps.queryItems = query
        return comps.url!
    }

    // MARK: - Internals

    func get(_ path: String) -> URLRequest { URLRequest(url: baseURL.appending(path: path)) }

    func authorizedSend<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await authorizedData(request)
        return try ABSAPI.decoder.decode(T.self, from: data)
    }

    func authorizedData(_ request: URLRequest) async throws -> Data {
        let token = try await auth.currentAccessToken()
        var authed = request
        authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(authed)
        if response.statusCode == 401 {
            let fresh = try await auth.refreshAfterAuthFailure(staleToken: token)
            var retry = request
            retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            let second = try await transport.send(retry)
            guard (200..<300).contains(second.statusCode) else { throw ABSError.http(status: second.statusCode) }
            return second.data
        }
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode) }
        return response.data
    }
}
```

- [ ] **Step 4: Run tests, expect pass; commit**

```bash
git add Packages/ABSKit
git commit -m "feat(ABSKit): ABSClient with 401-refresh-retry, libraries and items endpoints"
```

---

### Task 8: ABSClient playback endpoints + public track URL

**Files:**
- Modify: `Packages/ABSKit/Sources/ABSKit/ABSClient.swift` (add methods at end of class)
- Create: `Packages/ABSKit/Tests/ABSKitTests/PlaybackEndpointTests.swift`

**Interfaces:**
- Produces: `startPlayback(itemID:deviceInfo:)` (POST `/api/items/{id}/play`, body `{deviceInfo, mediaPlayer:"AVPlayer", supportedMimeTypes:[…], forceDirectPlay:false, forceTranscode:false}`), `syncSession(id:currentTime:timeListened:duration:)`, `closeSession(...)` (same body as sync), `publicTrackURL(sessionID:trackIndex:)` → `{base}/public/session/{id}/track/{index}`. Task 12 consumes all four.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
@testable import ABSKit

@Suite struct PlaybackEndpointTests {
    let base = URL(string: "http://abs.test:13378")!

    private func makeSUT() async -> (ABSClient, MockTransport) {
        let transport = MockTransport()
        let store = InMemoryTokenStore()
        await store.save(TokenPair(accessToken: "acc1", refreshToken: "ref1"), for: "c1")
        let auth = AuthManager(baseURL: base, connectionID: "c1", transport: transport, store: store)
        return (ABSClient(baseURL: base, transport: transport, auth: auth), transport)
    }

    private let sessionJSON = #"{"id":"ses_1","libraryItemId":"li_1","duration":100,"playMethod":0,"startTime":5,"currentTime":5,"audioTracks":[{"index":1,"startOffset":0,"duration":100,"contentUrl":"/api/items/li_1/file/1","mimeType":"audio/mpeg"}],"chapters":[]}"#

    @Test func startPlaybackPostsDeviceInfoAndMimeTypes() async throws {
        let (client, transport) = await makeSUT()
        await transport.enqueue(status: 200, json: sessionJSON)
        let device = DeviceInfo(deviceId: "dev-1", clientVersion: "0.1.0", model: "Mac16,1")
        let session = try await client.startPlayback(itemID: "li_1", deviceInfo: device)
        #expect(session.id == "ses_1")
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/items/li_1/play")
        #expect(req?.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Any]
        #expect((body["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "dev-1")
        #expect(body["mediaPlayer"] as? String == "AVPlayer")
        #expect((body["supportedMimeTypes"] as? [String])?.contains("audio/mpeg") == true)
        #expect(body["forceDirectPlay"] as? Bool == false)
        #expect(body["forceTranscode"] as? Bool == false)
    }

    @Test func syncPostsPayload() async throws {
        let (client, transport) = await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        try await client.syncSession(id: "ses_1", currentTime: 42.5, timeListened: 15, duration: 100)
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/session/ses_1/sync")
        let body = try JSONSerialization.jsonObject(with: req?.httpBody ?? Data()) as! [String: Double]
        #expect(body == ["currentTime": 42.5, "timeListened": 15, "duration": 100])
    }

    @Test func closePostsSamePayloadShape() async throws {
        let (client, transport) = await makeSUT()
        await transport.enqueue(status: 200, json: "{}")
        try await client.closeSession(id: "ses_1", currentTime: 99, timeListened: 3, duration: 100)
        let req = await transport.recorded.first
        #expect(req?.url?.absoluteString == "http://abs.test:13378/api/session/ses_1/close")
    }

    @Test func publicTrackURLUsesTrackIndexField() async {
        let (client, _) = await makeSUT()
        let url = client.publicTrackURL(sessionID: "ses_1", trackIndex: 2)
        #expect(url.absoluteString == "http://abs.test:13378/public/session/ses_1/track/2")
    }
}
```

- [ ] **Step 2: Run to verify failure** (`swift test --filter PlaybackEndpointTests` → FAIL)

- [ ] **Step 3: Add to `ABSClient`**

```swift
extension ABSClient {
    /// MIME types AVPlayer direct-plays; anything else transcodes to HLS server-side.
    static let supportedMimeTypes = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-m4b"]

    public func startPlayback(itemID: String, deviceInfo: DeviceInfo) async throws -> PlaybackSession {
        struct PlayRequest: Encodable {
            let deviceInfo: DeviceInfo
            let mediaPlayer: String
            let supportedMimeTypes: [String]
            let forceDirectPlay: Bool
            let forceTranscode: Bool
        }
        var req = URLRequest(url: baseURL.appending(path: "api/items/\(itemID)/play"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(PlayRequest(
            deviceInfo: deviceInfo, mediaPlayer: "AVPlayer",
            supportedMimeTypes: Self.supportedMimeTypes,
            forceDirectPlay: false, forceTranscode: false))
        return try await authorizedSend(req, as: PlaybackSession.self)
    }

    public func syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/sync",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    public func closeSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        try await postSessionPayload(path: "api/session/\(id)/close",
                                     currentTime: currentTime, timeListened: timeListened, duration: duration)
    }

    public func publicTrackURL(sessionID: String, trackIndex: Int) -> URL {
        baseURL.appending(path: "public/session/\(sessionID)/track/\(trackIndex)")
    }

    private func postSessionPayload(path: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ABSAPI.encoder.encode(
            ["currentTime": currentTime, "timeListened": timeListened, "duration": duration])
        _ = try await authorizedData(req)
    }
}
```

- [ ] **Step 4: Run all package tests, expect pass; commit**

```bash
git add Packages/ABSKit
git commit -m "feat(ABSKit): playback session endpoints and public track URLs"
```

---

### Task 9: Contract tests against the Docker server (opt-in)

**Files:**
- Create: `Packages/ABSKit/Tests/ABSKitTests/ContractTests.swift`

**Interfaces:**
- Consumes: everything in ABSKit; the seeded dev server (Task 2).
- Produces: confidence that our hand fixtures match reality, and empirical answers to two research open questions (public-track-URL index base; Range support). Suite is skipped unless `ABS_CONTRACT_URL` is set.

- [ ] **Step 1: Write the tests** (no failing-first here — these validate reality, not drive design)

```swift
import Foundation
import Testing
@testable import ABSKit

/// Run with: ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests
/// Requires `make server-up && make seed` first.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] != nil))
struct ContractTests {
    let base = URL(string: ProcessInfo.processInfo.environment["ABS_CONTRACT_URL"] ?? "http://invalid")!
    let transport = URLSessionTransport()

    private func loggedInClient() async throws -> ABSClient {
        let store = InMemoryTokenStore()
        let auth = AuthManager(baseURL: base, connectionID: "contract", transport: transport, store: store)
        _ = try await auth.login(username: "root", password: "colophon-dev")
        return ABSClient(baseURL: base, transport: transport, auth: auth)
    }

    @Test func statusReportsSupportedVersion() async throws {
        let status = try await ABSClient.status(baseURL: base, transport: transport)
        #expect(status.isInit == true)
        #expect(status.serverVersion?.hasPrefix("2.3") == true)
    }

    @Test func fullPlaybackLifecycle() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        #expect(!libs.isEmpty)
        let page = try await client.items(libraryID: libs[0].id, limit: 10, page: 0)
        #expect(page.total >= 1)

        let device = DeviceInfo(deviceId: "contract-test", clientVersion: "0.1.0", model: "test")
        let session = try await client.startPlayback(itemID: page.results[0].id, deviceInfo: device)
        #expect(!session.audioTracks.isEmpty)
        #expect(session.playMethod == 0)  // seeded mp3s must direct-play

        // Empirical: public track URL serves audio for the track's own index value.
        let track = session.audioTracks[0]
        let trackURL = client.publicTrackURL(sessionID: session.id, trackIndex: track.index)
        var head = URLRequest(url: trackURL)
        head.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let ranged = try await transport.send(head)
        #expect(ranged.statusCode == 206, "expected partial content; got \(ranged.statusCode) — check index base or Range support")
        #expect(ranged.data.count == 1024)

        try await client.syncSession(id: session.id, currentTime: 30, timeListened: 15, duration: session.duration)
        try await client.closeSession(id: session.id, currentTime: 30, timeListened: 0, duration: session.duration)
    }

    @Test func coverEndpointIsUnauthenticated() async throws {
        let client = try await loggedInClient()
        let libs = try await client.libraries()
        let page = try await client.items(libraryID: libs[0].id, limit: 1, page: 0)
        let url = client.coverURL(itemID: page.results[0].id, width: 200, updatedAt: page.results[0].updatedAt)
        let response = try await transport.send(URLRequest(url: url))  // no Authorization header
        #expect(response.statusCode == 200)
    }
}
```

- [ ] **Step 2: Run against the live server**

Run: `make server-up && make seed && cd Packages/ABSKit && ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests`
Expected: PASS. **If `fullPlaybackLifecycle` fails on the 206 assertion, the track-index base assumption is wrong — try array position instead of `track.index`, and record the true behavior in a code comment on `publicTrackURL`.**

- [ ] **Step 3: Verify default runs skip the suite**

Run: `cd Packages/ABSKit && swift test`
Expected: ContractTests reported as skipped; all others pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/ABSKit
git commit -m "test(ABSKit): opt-in contract tests against dockerized ABS server"
```

---

### Task 10: BookTimeline math

**Files:**
- Create: `Packages/PlayerEngine/Sources/PlayerEngine/BookTimeline.swift`
- Create: `Packages/PlayerEngine/Tests/PlayerEngineTests/BookTimelineTests.swift`
- Delete: placeholder test from Task 1.

**Interfaces:**
- Consumes: `AudioTrack` from ABSKit.
- Produces: `BookTimeline` per contract block. Task 12 uses `position(at:)` for seeks and `globalTime(trackIndex:offset:)` for progress display.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import ABSKit
@testable import PlayerEngine

private func track(_ index: Int, _ start: Double, _ duration: Double) -> AudioTrack {
    let json = """
    {"index":\(index),"startOffset":\(start),"duration":\(duration)}
    """
    return try! JSONDecoder().decode(AudioTrack.self, from: Data(json.utf8))
}

@Suite struct BookTimelineTests {
    // Three tracks: [0,10), [10,25), [25,30)
    let timeline = BookTimeline(tracks: [track(1, 0, 10), track(2, 10, 15), track(3, 25, 5)])

    @Test func totalDurationSumsTracks() {
        #expect(timeline.totalDuration == 30)
    }

    @Test func mapsGlobalTimeIntoTracks() {
        #expect(timeline.position(at: 0) == .init(trackIndex: 0, offset: 0))
        #expect(timeline.position(at: 9.5) == .init(trackIndex: 0, offset: 9.5))
        #expect(timeline.position(at: 10) == .init(trackIndex: 1, offset: 0))
        #expect(timeline.position(at: 24.9) == .init(trackIndex: 1, offset: 14.9))
        #expect(timeline.position(at: 29) == .init(trackIndex: 2, offset: 4))
    }

    @Test func clampsOutOfRange() {
        #expect(timeline.position(at: -5) == .init(trackIndex: 0, offset: 0))
        #expect(timeline.position(at: 30) == .init(trackIndex: 2, offset: 5))
        #expect(timeline.position(at: 999) == .init(trackIndex: 2, offset: 5))
    }

    @Test func globalTimeIsInverse() {
        #expect(timeline.globalTime(trackIndex: 1, offset: 14.9) == 24.9)
        #expect(timeline.globalTime(trackIndex: 0, offset: 0) == 0)
        #expect(timeline.globalTime(trackIndex: 2, offset: 4) == 29)
    }

    @Test func unsortedInputIsSorted() {
        let shuffled = BookTimeline(tracks: [track(3, 25, 5), track(1, 0, 10), track(2, 10, 15)])
        #expect(shuffled.position(at: 12) == .init(trackIndex: 1, offset: 2))
    }

    @Test func singleTrackBook() {
        let single = BookTimeline(tracks: [track(1, 0, 3600)])
        #expect(single.position(at: 1800) == .init(trackIndex: 0, offset: 1800))
        #expect(single.totalDuration == 3600)
    }
}
```

- [ ] **Step 2: Run to verify failure** (`cd Packages/PlayerEngine && swift test` → FAIL)

- [ ] **Step 3: Implement `BookTimeline.swift`**

```swift
import Foundation
import ABSKit

/// Maps a book's single logical timeline onto its (possibly many) audio files.
/// `trackIndex` here is the position in the sorted array, NOT AudioTrack.index.
public struct BookTimeline: Sendable {
    public struct Position: Equatable, Sendable {
        public let trackIndex: Int
        public let offset: TimeInterval
        public init(trackIndex: Int, offset: TimeInterval) {
            self.trackIndex = trackIndex; self.offset = offset
        }
    }

    public let tracks: [AudioTrack]

    public init(tracks: [AudioTrack]) {
        self.tracks = tracks.sorted { $0.startOffset < $1.startOffset }
    }

    public var totalDuration: TimeInterval {
        guard let last = tracks.last else { return 0 }
        return last.startOffset + last.duration
    }

    public func position(at globalTime: TimeInterval) -> Position {
        guard !tracks.isEmpty else { return Position(trackIndex: 0, offset: 0) }
        let clamped = min(max(globalTime, 0), totalDuration)
        for (i, track) in tracks.enumerated() {
            let end = track.startOffset + track.duration
            if clamped < end || i == tracks.count - 1 {
                return Position(trackIndex: i, offset: min(clamped - track.startOffset, track.duration))
            }
        }
        return Position(trackIndex: 0, offset: 0)
    }

    public func globalTime(trackIndex: Int, offset: TimeInterval) -> TimeInterval {
        guard tracks.indices.contains(trackIndex) else { return 0 }
        return tracks[trackIndex].startOffset + offset
    }
}
```

- [ ] **Step 4: Run tests, expect pass; commit**

```bash
git add Packages/PlayerEngine
git commit -m "feat(PlayerEngine): BookTimeline global-time/track mapping"
```

---

### Task 11: SessionSyncController — cadence and delta accounting

**Files:**
- Create: `Packages/PlayerEngine/Sources/PlayerEngine/SessionSyncController.swift`
- Create: `Packages/PlayerEngine/Tests/PlayerEngineTests/SessionSyncControllerTests.swift`

**Interfaces:**
- Produces: `SessionSyncController` + `SyncPayload` per contract block. Semantics: `noteProgress` accumulates listened seconds on every call; returns a payload only when ≥ `interval` has elapsed since the last emitted payload (or since init). `didSync()` resets accumulated time (call ONLY after server 200). If a sync fails, the caller does not call `didSync()`, so the next payload carries the accumulated total. `flush(currentTime:)` returns a payload with whatever is accumulated (for pause/close), or nil if zero.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
@testable import PlayerEngine

@Suite struct SessionSyncControllerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func emitsNothingBeforeInterval() {
        var sut = SessionSyncController(interval: 15)
        #expect(sut.noteProgress(currentTime: 1, listenedDelta: 1, now: t0) == nil)
        #expect(sut.noteProgress(currentTime: 14, listenedDelta: 13, now: t0.addingTimeInterval(13)) == nil)
    }

    @Test func emitsAccumulatedListenedTimeAtInterval() {
        var sut = SessionSyncController(interval: 15)
        _ = sut.noteProgress(currentTime: 5, listenedDelta: 5, now: t0.addingTimeInterval(5))
        let payload = sut.noteProgress(currentTime: 16, listenedDelta: 11, now: t0.addingTimeInterval(16))
        #expect(payload == SyncPayload(currentTime: 16, timeListened: 16))
    }

    @Test func didSyncResetsAccumulation() {
        var sut = SessionSyncController(interval: 15)
        _ = sut.noteProgress(currentTime: 16, listenedDelta: 16, now: t0.addingTimeInterval(16))
        sut.didSync()
        let payload = sut.noteProgress(currentTime: 32, listenedDelta: 16, now: t0.addingTimeInterval(32))
        #expect(payload == SyncPayload(currentTime: 32, timeListened: 16))
    }

    @Test func failedSyncKeepsAccumulating() {
        var sut = SessionSyncController(interval: 15)
        let first = sut.noteProgress(currentTime: 15, listenedDelta: 15, now: t0.addingTimeInterval(15))
        #expect(first?.timeListened == 15)
        // caller's POST failed → no didSync(); 15 more seconds pass
        let second = sut.noteProgress(currentTime: 30, listenedDelta: 15, now: t0.addingTimeInterval(30))
        #expect(second == SyncPayload(currentTime: 30, timeListened: 30))
    }

    @Test func flushEmitsRemainderOrNil() {
        var sut = SessionSyncController(interval: 15)
        #expect(sut.flush(currentTime: 0) == nil)
        _ = sut.noteProgress(currentTime: 4, listenedDelta: 4, now: t0.addingTimeInterval(4))
        #expect(sut.flush(currentTime: 4) == SyncPayload(currentTime: 4, timeListened: 4))
        sut.didSync()
        #expect(sut.flush(currentTime: 4) == nil)
    }

    @Test func seekingDoesNotCountAsListening() {
        var sut = SessionSyncController(interval: 15)
        // User scrubbed from 10 to 500: currentTime jumps, listenedDelta stays real.
        _ = sut.noteProgress(currentTime: 500, listenedDelta: 1, now: t0.addingTimeInterval(16))
        let payload = sut.flush(currentTime: 500)
        #expect(payload == SyncPayload(currentTime: 500, timeListened: 1))
    }
}
```

- [ ] **Step 2: Run to verify failure** (FAIL — type not defined)

- [ ] **Step 3: Implement `SessionSyncController.swift`**

```swift
import Foundation

public struct SyncPayload: Equatable, Sendable {
    public let currentTime: Double
    public let timeListened: Double
    public init(currentTime: Double, timeListened: Double) {
        self.currentTime = currentTime; self.timeListened = timeListened
    }
}

/// Accumulates listened-time deltas and decides when a session sync is due.
/// `timeListened` semantics per ABS server: seconds listened SINCE LAST SUCCESSFUL sync.
public struct SessionSyncController: Sendable {
    private let interval: TimeInterval
    private var accumulatedListened: Double = 0
    private var lastEmission: Date?

    public init(interval: TimeInterval = 15) {
        self.interval = interval
    }

    public mutating func noteProgress(currentTime: TimeInterval, listenedDelta: TimeInterval, now: Date) -> SyncPayload? {
        accumulatedListened += max(0, listenedDelta)
        let reference = lastEmission ?? now.addingTimeInterval(-min(accumulatedListened, interval))
        let due = lastEmission.map { now.timeIntervalSince($0) >= interval }
            ?? (accumulatedListened >= interval || now.timeIntervalSince(reference) >= interval)
        guard due else { return nil }
        lastEmission = now
        return SyncPayload(currentTime: currentTime, timeListened: accumulatedListened)
    }

    public mutating func didSync() {
        accumulatedListened = 0
    }

    public mutating func flush(currentTime: TimeInterval) -> SyncPayload? {
        guard accumulatedListened > 0 else { return nil }
        return SyncPayload(currentTime: currentTime, timeListened: accumulatedListened)
    }
}
```

- [ ] **Step 4: Run tests; iterate until the exact semantics above pass; commit**

Run: `cd Packages/PlayerEngine && swift test`
Expected: PASS.

```bash
git add Packages/PlayerEngine
git commit -m "feat(PlayerEngine): session sync cadence + listened-delta accounting"
```

---

### Task 12: PlayerEngine (AVQueuePlayer) + NowPlayingUpdater + walking-skeleton UI

This is the integration task: real AVPlayer, real UI, manual E2E. Unit tests cover what is deterministic (already done in Tasks 10–11); AVFoundation wiring is verified against the dev server via the checklist below.

**Files:**
- Create: `Packages/PlayerEngine/Sources/PlayerEngine/PlayerEngine.swift` (replace placeholder file content)
- Create: `Packages/PlayerEngine/Sources/PlayerEngine/NowPlayingUpdater.swift`
- Create: `App/AppState.swift`, `App/Views/ConnectView.swift`, `App/Views/LibrariesView.swift`, `App/Views/LibraryItemsView.swift`, `App/Views/PlayerBarView.swift`
- Modify: `App/ColophonApp.swift`

**Interfaces:**
- Consumes: `ABSClient`, `AuthManager`, `PlaybackSession`, `BookTimeline`, `SessionSyncController`.
- Produces: `@MainActor @Observable final class PlaybackController` (in PlayerEngine): `load(session:urlProvider:)`, `play()`, `pause()`, `togglePlayPause()`, `skip(_ seconds: Double)`, `seek(toGlobal: TimeInterval)`, `setRate(Float)`, observable `isPlaying: Bool`, `globalTime: TimeInterval`, `totalDuration: TimeInterval`, `rate: Float`, `title: String`, `author: String`, and `onSyncDue: ((SyncPayload) async -> Bool)?` (return true = synced OK → controller calls `didSync()`).

- [ ] **Step 1: Implement `PlayerEngine.swift`**

```swift
import Foundation
import AVFoundation
import ABSKit

@MainActor
@Observable
public final class PlaybackController {
    public private(set) var isPlaying = false
    public private(set) var globalTime: TimeInterval = 0
    public private(set) var totalDuration: TimeInterval = 0
    public private(set) var title = ""
    public private(set) var author = ""
    public var rate: Float = 1.0 { didSet { if isPlaying { player?.rate = rate } ; player?.defaultRate = rate } }

    /// Return true if the payload reached the server (controller then resets the delta).
    public var onSyncDue: ((SyncPayload) async -> Bool)?

    private var player: AVQueuePlayer?
    private var timeline = BookTimeline(tracks: [])
    private var items: [AVPlayerItem] = []
    private var currentTrackIndex = 0
    private var timeObserver: Any?
    private var sync = SessionSyncController()
    private var lastTickGlobalTime: TimeInterval = 0
    private let nowPlaying = NowPlayingUpdater()

    public init() {}

    public func load(session: PlaybackSession, urlProvider: (AudioTrack) -> URL) {
        unload()
        timeline = BookTimeline(tracks: session.audioTracks)
        totalDuration = timeline.totalDuration
        title = session.displayTitle ?? "Untitled"
        author = session.displayAuthor ?? ""
        sync = SessionSyncController()

        items = timeline.tracks.map { track in
            let item = AVPlayerItem(url: urlProvider(track))
            item.audioTimePitchAlgorithm = .spectral
            return item
        }

        let start = timeline.position(at: session.startTime)
        let queue = AVQueuePlayer(items: Array(items[start.trackIndex...]))
        queue.defaultRate = rate
        currentTrackIndex = start.trackIndex
        player = queue
        queue.seek(to: CMTime(seconds: start.offset, preferredTimescale: 1000),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        globalTime = session.startTime
        lastTickGlobalTime = session.startTime

        installObservers(queue)
        nowPlaying.configure(controller: self)
        configureAudioSession()
    }

    public func play() {
        player?.play()
        player?.rate = rate
        isPlaying = true
        nowPlaying.update(controller: self)
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        nowPlaying.update(controller: self)
        Task { await flushSync() }
    }

    public func togglePlayPause() { isPlaying ? pause() : play() }

    public func skip(_ seconds: Double) { seek(toGlobal: globalTime + seconds) }

    public func seek(toGlobal target: TimeInterval) {
        guard let player else { return }
        let pos = timeline.position(at: target)
        if pos.trackIndex != currentTrackIndex {
            rebuildQueue(from: pos.trackIndex)
        }
        player.seek(to: CMTime(seconds: pos.offset, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        globalTime = timeline.globalTime(trackIndex: pos.trackIndex, offset: pos.offset)
        lastTickGlobalTime = globalTime
        nowPlaying.update(controller: self)
    }

    public func setRate(_ newRate: Float) { rate = newRate }

    public func unload() {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Internals

    private func rebuildQueue(from trackIndex: Int) {
        guard let player else { return }
        player.removeAllItems()
        for item in items[trackIndex...] {
            // Items can only be enqueued once; recreate if already played.
            let fresh = item.currentTime() == .zero && player.canInsert(item, after: nil)
                ? item
                : AVPlayerItem(asset: item.asset)
            fresh.audioTimePitchAlgorithm = .spectral
            player.insert(fresh, after: nil)
        }
        currentTrackIndex = trackIndex
        if isPlaying { player.play(); player.rate = rate }
    }

    private func installObservers(_ queue: AVQueuePlayer) {
        timeObserver = queue.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(trackTime: time.seconds) }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let finished = note.object as? AVPlayerItem else { return }
                if self.player?.items().first !== finished { self.currentTrackIndex += 1 }
                if self.currentTrackIndex >= self.timeline.tracks.count {
                    self.pause()  // book finished
                }
            }
        }
    }

    private func tick(trackTime: TimeInterval) {
        guard isPlaying else { return }
        globalTime = timeline.globalTime(trackIndex: currentTrackIndex, offset: trackTime)
        let delta = max(0, globalTime - lastTickGlobalTime)
        lastTickGlobalTime = globalTime
        // Wall-clock listened time ≈ timeline delta / rate; ABS expects real seconds listened.
        let listened = Double(delta) / Double(max(rate, 0.1))
        if let payload = sync.noteProgress(currentTime: globalTime, listenedDelta: listened, now: Date()),
           let onSyncDue {
            Task {
                if await onSyncDue(payload) { self.sync.didSync() }
            }
        }
        nowPlaying.updateElapsed(controller: self)
    }

    private func flushSync() async {
        if let payload = sync.flush(currentTime: globalTime), let onSyncDue {
            if await onSyncDue(payload) { sync.didSync() }
        }
    }

    private func configureAudioSession() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, policy: .longFormAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
```

- [ ] **Step 2: Implement `NowPlayingUpdater.swift`**

```swift
import Foundation
import MediaPlayer

@MainActor
final class NowPlayingUpdater {
    func configure(controller: PlaybackController) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak controller] _ in
            MainActor.assumeIsolated { controller?.play() }; return .success
        }
        center.pauseCommand.addTarget { [weak controller] _ in
            MainActor.assumeIsolated { controller?.pause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak controller] _ in
            MainActor.assumeIsolated { controller?.togglePlayPause() }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak controller] _ in
            MainActor.assumeIsolated { controller?.skip(15) }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak controller] _ in
            MainActor.assumeIsolated { controller?.skip(-15) }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak controller] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { controller?.seek(toGlobal: event.positionTime) }
            return .success
        }
        update(controller: controller)
    }

    func update(controller: PlaybackController) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: controller.title,
            MPMediaItemPropertyArtist: controller.author,
            MPMediaItemPropertyPlaybackDuration: controller.totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: controller.globalTime,
            MPNowPlayingInfoPropertyPlaybackRate: controller.isPlaying ? controller.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: controller.rate,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // Required on macOS or media keys / Control Center ignore the app.
        MPNowPlayingInfoCenter.default().playbackState = controller.isPlaying ? .playing : .paused
        #endif
    }

    func updateElapsed(controller: PlaybackController) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = controller.globalTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = controller.isPlaying ? controller.rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
```

- [ ] **Step 3: Build both packages** (`make test`) — PlayerEngine must still compile with strict concurrency. Fix isolation errors before proceeding.

- [ ] **Step 4: Implement `App/AppState.swift`**

```swift
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
            errorMessage = "Could not connect: \(error.localizedDescription)"
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
}
```

- [ ] **Step 5: Implement the views**

`App/Views/ConnectView.swift`:

```swift
import SwiftUI

struct ConnectView: View {
    @Environment(AppState.self) private var app
    @State private var serverURL = "http://localhost:13378"
    @State private var username = "root"
    @State private var password = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            if let error = app.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Button(app.phase == .connecting ? "Connecting…" : "Connect") {
                Task { await app.connect(serverURL: serverURL, username: username, password: password) }
            }
            .disabled(app.phase == .connecting)
        }
        .formStyle(.grouped)
        .navigationTitle("Colophon")
        .fontDesign(.serif)
        .frame(maxWidth: 480)
    }
}
```

`App/Views/LibrariesView.swift`:

```swift
import SwiftUI
import ABSKit

struct LibrariesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List(app.libraries) { library in
            NavigationLink(library.name, value: library)
        }
        .navigationTitle("Libraries")
        .navigationDestination(for: Library.self) { LibraryItemsView(library: $0) }
    }
}
```

`App/Views/LibraryItemsView.swift`:

```swift
import SwiftUI
import ABSKit

struct LibraryItemsView: View {
    @Environment(AppState.self) private var app
    let library: Library
    @State private var items: [LibraryItemSummary] = []
    @State private var total = 0
    @State private var page = 0
    private let pageSize = 50

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    Button {
                        Task { await app.startPlayback(item: item) }
                    } label: {
                        VStack(alignment: .leading) {
                            AsyncImage(url: app.client?.coverURL(itemID: item.id, width: 300, updatedAt: item.updatedAt)) { image in
                                image.resizable().aspectRatio(contentMode: .fit)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(item.media.metadata.title ?? "Untitled").font(.headline).lineLimit(2)
                            Text(item.media.metadata.authorName ?? "").font(.subheadline)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .padding()
        }
        .fontDesign(.serif)
        .navigationTitle(library.name)
        .task { await loadMore() }
    }

    private func loadMore() async {
        guard let client = app.client, items.count < total || page == 0 else { return }
        if let result = try? await client.items(libraryID: library.id, limit: pageSize, page: page) {
            items.append(contentsOf: result.results)
            total = result.total
            page += 1
        }
    }
}
```

`App/Views/PlayerBarView.swift`:

```swift
import SwiftUI

struct PlayerBarView: View {
    @Environment(AppState.self) private var app
    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        let playback = app.playback
        if playback.totalDuration > 0 {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(playback.title).font(.headline).lineLimit(1)
                        Text(playback.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { playback.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    }
                    Button { playback.skip(15) } label: { Image(systemName: "goforward.15") }
                    Menu(String(format: "%.2g×", playback.rate)) {
                        ForEach(rates, id: \.self) { rate in
                            Button(String(format: "%.2g×", rate)) { playback.setRate(rate) }
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(timeString(playback.globalTime)).monospacedDigit().font(.caption)
                    Slider(
                        value: Binding(
                            get: { playback.globalTime },
                            set: { playback.seek(toGlobal: $0) }),
                        in: 0...max(playback.totalDuration, 1))
                    Text(timeString(playback.totalDuration)).monospacedDigit().font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .fontDesign(.serif)
            .padding(12)
            .background(.bar)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
```

- [ ] **Step 6: Wire up `App/ColophonApp.swift`**

```swift
import SwiftUI

@main
struct ColophonApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if app.phase == .connected {
                    NavigationStack { LibrariesView() }
                        .safeAreaInset(edge: .bottom) { PlayerBarView() }
                } else {
                    NavigationStack { ConnectView() }
                }
            }
            .environment(app)
        }
    }
}
```

- [ ] **Step 7: Build both platforms**

Run: `make build-ios && make build-mac`
Expected: `BUILD SUCCEEDED` twice. Fix any strict-concurrency or platform-conditional issues now.

- [ ] **Step 8: Manual E2E checklist (iPhone simulator)** — server running + seeded

1. `make server-up && make seed`, then run the `Colophon` scheme on the iPhone 17 simulator (⌘R in Xcode after `make gen`, or `xcodebuild ... run` equivalent).
2. Connect with `http://localhost:13378` / `root` / `colophon-dev` → Libraries shows "Books".
3. Open Books → cover grid shows *The Art of War* with artwork.
4. Tap it → audio starts within ~2s; player bar shows title, elapsed counts up.
5. Scrub the slider past the first track boundary (~10 min) → playback continues from the later file (multi-track seek works).
6. Set rate 1.5× → audibly faster, pitch-corrected.
7. Background the app (Home) → audio continues; lock-screen/Now Playing shows Colophon with working play/pause and ±15s.
8. Wait ≥30 s of playback, then open `http://localhost:13378` in a browser → the item shows progress at ≈ the app's position (session sync works). Pause the app → progress updates again (flush works).

- [ ] **Step 9: Manual E2E checklist (Mac)**

1. Run the `Colophon` scheme with My Mac destination.
2. Repeat connect → browse → play (window resizes sanely; grid reflows).
3. Press the keyboard **play/pause media key (F8)** → toggles playback (requires `playbackState` — this validates NowPlayingUpdater's macOS path).
4. Control Center → Now Playing shows Colophon with artwork-less title/author and working controls.
5. Progress reaches the server as in step 8 above.

- [ ] **Step 10: Commit**

```bash
git add App Packages Makefile project.yml
git commit -m "feat: walking skeleton — connect, browse, stream with progress sync on iOS and macOS"
```

---

### Task 13: Spike — socket.io-client-swift handshake against ABS 4.5.x

**Files:**
- Create: `Tools/SocketSpike/Package.swift`, `Tools/SocketSpike/Sources/SocketSpike/main.swift`
- Create: `docs/superpowers/spikes/2026-07-socketio-handshake.md`

**Interfaces:**
- Consumes: dev server (Task 2).
- Produces: a go/no-go decision + working configuration for M1's real-time layer. Throwaway code — never imported by the app.

- [ ] **Step 1: Write the spike executable**

`Tools/SocketSpike/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SocketSpike",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "SocketSpike",
            dependencies: [.product(name: "SocketIO", package: "socket.io-client-swift")]),
    ]
)
```

`Tools/SocketSpike/Sources/SocketSpike/main.swift`:

```swift
import Foundation
import SocketIO

// Usage: swift run SocketSpike http://localhost:13378 <accessToken>
let args = CommandLine.arguments
guard args.count == 3, let url = URL(string: args[1]) else {
    print("usage: SocketSpike <serverURL> <accessToken>"); exit(2)
}
let token = args[2]

let manager = SocketManager(socketURL: url, config: [
    .log(true), .forceWebsockets(true), .version(.three), .compress,
])
let socket = manager.defaultSocket
var outcome = 1

socket.on(clientEvent: .connect) { _, _ in
    print("CONNECTED — emitting auth")
    socket.emit("auth", token)
}
socket.on("init") { data, _ in
    print("INIT RECEIVED: \(data)")
    outcome = 0
    exit(0)
}
socket.on("auth_failed") { data, _ in
    print("AUTH FAILED: \(data)")
    exit(1)
}
socket.on(clientEvent: .error) { data, _ in print("ERROR: \(data)") }

socket.connect()
RunLoop.main.run(until: Date().addingTimeInterval(15))
print("TIMEOUT — no init/auth_failed within 15s")
exit(outcome)
```

- [ ] **Step 2: Run against the dev server**

```bash
TOKEN=$(curl -fsS -X POST http://localhost:13378/login -H 'Content-Type: application/json' \
  -H 'x-return-tokens: true' -d '{"username":"root","password":"colophon-dev"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"]["accessToken"])')
cd Tools/SocketSpike && swift run SocketSpike http://localhost:13378 "$TOKEN"; echo "exit=$?"
```

Expected: `INIT RECEIVED` and `exit=0`. If `.version(.three)` fails to connect, try removing the option (library default) and record which config works.

- [ ] **Step 3: Document the outcome**

Write `docs/superpowers/spikes/2026-07-socketio-handshake.md`: library version tested, exact working `SocketManager` config, whether `init` arrived with `userId`, reconnect behavior observed (kill/restart the container while connected), and the M1 recommendation (adopt vs. poll fallback).

- [ ] **Step 4: Commit**

```bash
git add Tools docs/superpowers/spikes
git commit -m "spike: socket.io v4 handshake against ABS — outcome documented"
```

---

### Task 14: Spike — macOS grid performance at 10k items

**Files:**
- Create: `App/Views/PerfSpikeView.swift`
- Modify: `App/ColophonApp.swift` (add DEBUG-only Commands entry)
- Create: `docs/superpowers/spikes/2026-07-macos-grid-perf.md`

**Interfaces:**
- Produces: a decision for the M3 Mac shell: LazyVGrid is fine / needs tuning / needs NSCollectionView fallback.

- [ ] **Step 1: Write `App/Views/PerfSpikeView.swift`**

```swift
#if DEBUG
import SwiftUI

/// Synthetic 10k-item grid to probe LazyVGrid scroll performance on macOS.
struct PerfSpikeView: View {
    struct Cell: Identifiable { let id: Int }
    let cells = (0..<10_000).map(Cell.init)
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(cells) { cell in
                    VStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                colors: [.blue.opacity(Double(cell.id % 10) / 10 + 0.05), .purple],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .aspectRatio(1, contentMode: .fit)
                        Text("Synthetic Book \(cell.id)").font(.headline).lineLimit(1)
                        Text("Author \(cell.id % 500)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .fontDesign(.serif)
        .navigationTitle("Perf Spike — 10k items")
    }
}
#endif
```

- [ ] **Step 2: Add a DEBUG window** — in `ColophonApp.swift`, append to the `body: some Scene`:

```swift
#if DEBUG && os(macOS)
Window("Perf Spike", id: "perf-spike") { PerfSpikeView() }
#endif
```

- [ ] **Step 3: Run the probe on the Mac**

Build & run on My Mac. Open Window ▸ Perf Spike. With Instruments (Animation Hitches template) or by eye at minimum: fast continuous scroll top-to-bottom twice, then jump-scroll via scroller drag. Record: initial render time, hitching during fast scroll, memory at rest after full scroll.

- [ ] **Step 4: Document verdict** in `docs/superpowers/spikes/2026-07-macos-grid-perf.md`: measurements, verdict (`LazyVGrid OK` / `needs cell simplification` / `plan NSCollectionView wrapper for M3`), and any settings that mattered.

- [ ] **Step 5: Commit**

```bash
git add App docs/superpowers/spikes
git commit -m "spike: macOS LazyVGrid 10k-item performance probe + verdict"
```

---

### Task 15: M0 wrap-up

**Files:**
- Create: `README.md`
- Modify: `docs/superpowers/carplay-entitlement.md` (status check)

**Interfaces:** none — closure task.

- [ ] **Step 1: Write `README.md`**

```markdown
# Colophon

A native audiobook & podcast client for [Audiobookshelf](https://www.audiobookshelf.org)
across iPhone, iPad, Mac, Apple TV, Vision Pro, and Apple Watch. Serif-typeset,
Liquid Glass, and unapologetically Mac-assed on the Mac.

**Status:** M0 walking skeleton — password login, library browse, multi-file
streaming playback with server progress sync, on iOS + macOS.

## Development

Requirements: Xcode 26.6, XcodeGen (`brew install xcodegen`), Docker.

    make gen          # generate Colophon.xcodeproj
    make server-up    # start dev Audiobookshelf at localhost:13378
    make seed         # root/colophon-dev + a LibriVox test book
    make test         # package unit tests
    make build-ios build-mac

Contract tests: `ABS_CONTRACT_URL=http://localhost:13378 swift test --filter ContractTests`
(from `Packages/ABSKit`).

Design spec: `docs/superpowers/specs/2026-07-06-audiobookshelf-apple-client-design.md`
```

- [ ] **Step 2: Full verification sweep**

Run: `make test && make build-ios && make build-mac`, then re-run the contract suite against a freshly reset server (`make server-down && rm -rf devserver/data && make server-up && make seed`).
Expected: everything green from a cold start.

- [ ] **Step 3: Check CarPlay entitlement status** — update `docs/superpowers/carplay-entitlement.md` if Apple has responded.

- [ ] **Step 4: Commit and tag**

```bash
git add -A
git commit -m "docs: README and M0 wrap-up"
git tag m0-walking-skeleton
```

---

## Self-review notes (performed at plan-writing time)

- **Spec coverage (M0 scope only):** scaffold ✔ (T1), CarPlay filing ✔ (T0), password auth ✔ (T4–T6), library list ✔ (T7), E2E streaming on iPhone+Mac ✔ (T8, T12), socket spike ✔ (T13), Mac grid spike ✔ (T14). OIDC/downloads/GRDB/widgets deliberately absent (M1/M2 per spec).
- **Known simplifications accepted for M0** (recorded so M1 planning picks them up): no chapter UI (session data already carries chapters), no per-book rate persistence, sync-404 recovery is out (logged in spec §PlayerEngine for M1), `rebuildQueue` recreates played items conservatively, `AppState` model string is coarse ("Mac"/"iPhone").
- **Type consistency:** `BookTimeline.Position.trackIndex` is array position; `publicTrackURL(trackIndex:)` takes `AudioTrack.index` — the two are deliberately distinct and Task 12's `urlProvider` closure passes `track.index` while queue math uses array positions. Contract test (T9) empirically validates the index base.
