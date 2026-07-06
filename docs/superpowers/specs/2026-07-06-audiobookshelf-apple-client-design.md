# Native Apple Audiobookshelf Client — Design Spec

**Date:** 2026-07-06
**Status:** Approved (user-reviewed 2026-07-06)
**Name:** **Colophon** — App Store listing "Colophon — for Audiobookshelf" (nominative-use pattern shared by other third-party clients). Collision-checked 2026-07-06: no App Store name matches; nearest brand (Colophon Foundry) is a Monotype-owned type foundry, different category. OIDC URL scheme: `colophon://oauth`.

## 1. Overview

A single native SwiftUI application for **iOS, iPadOS, macOS, tvOS, visionOS, and watchOS** that connects to self-hosted [Audiobookshelf](https://www.audiobookshelf.org) servers for audiobook and podcast listening, with iCloud-synced preferences and server connections.

**Why it should exist (verified July 2026):** the official Audiobookshelf iOS app has never shipped to the App Store (TestFlight-only; 10k-tester beta full). No purpose-built native macOS client exists at all, tvOS has only two hobby projects not on the App Store, and visionOS has zero native clients. The strongest competitors (ShelfPlayer, plappa, AudioBooth, Still) are iPhone/iPad-first. **The Mac experience is this project's reason to exist**; tvOS and visionOS are unclaimed territory.

### Goals

1. Best-in-class *Mac-assed* macOS app — windows, menus, shortcuts, menu-bar extra, mini-player; never an iPad port.
2. One codebase, six platforms, each with a platform-tailored shell (no lowest-common-denominator UI).
3. Rock-solid playback and progress sync, including fully offline listening with sync-back.
4. iCloud-synced server connections and preferences — sign in once per device, everything else follows you.
5. A distinct, book-ish visual identity: serif-first typography (New York), Liquid Glass done per HIG.

### Non-goals (v1)

- Ebook reading (ABS serves epub/pdf; we consciously skip it — audio only).
- Server administration (library scans, user management, podcast RSS search/add, feed hosting).
- Android/web. Jellyfin/Plex backends. Bundled/local-only libraries (server required).

## 2. Locked product decisions

| Decision | Choice |
|---|---|
| Offline downloads | In v1, with offline progress sync-back |
| Companion surfaces | CarPlay, Widgets + Live Activity, Siri/App Intents — all v1; watchOS in scope, final milestone |
| Distribution | App Store, free; consumable-IAP **tip jar** (no paywalled features) |
| Deployment targets | iOS/iPadOS/macOS/tvOS/visionOS/watchOS **26+** (Liquid Glass baseline; no legacy conditionals) |
| Toolchain | Xcode 26.6 / 26.5 SDKs for releases; Xcode 27 beta for exploratory testing only |
| Server support | Audiobookshelf **≥ v2.26.0** (JWT access/refresh auth). No legacy-token support |
| Typography | Serif (New York, `.fontDesign(.serif)`) as the default content typeface; Settings toggle to San Francisco; monospaced digits for timers |

## 3. Architecture

**Approach:** one multiplatform Xcode app target (iOS/iPadOS/macOS/tvOS/visionOS) + a watchOS app target + extension targets (widgets, Live Activity, Control widgets), all thin shells over local Swift packages. Swift 6.2, default-MainActor app modules, `@Observable` state.

### Packages

```
ABSApp (workspace)
├── App/                    multiplatform app target + watch target + extensions
└── Packages/
    ├── ABSKit              server API client (REST + Socket.IO), auth, DTOs
    ├── PlayerEngine        AVQueuePlayer engine, now-playing, sleep timer, session sync
    ├── LibraryCache        GRDB store: cached library data, FTS5 search, observation
    ├── DownloadManager     background URLSession downloads, offline bookkeeping
    ├── CloudSync           CKSyncEngine (connections, per-book prefs) + KVS (simple prefs)
    └── AppUI               design system: typography, covers, shelves, player components
```

Each package has one clear purpose, communicates through small protocol surfaces, and is independently testable. UI never talks to the network directly; it observes `LibraryCache`/`PlayerEngine` state.

### ABSKit (server contract — key verified behaviors)

- **Auth:** `POST /login` with `x-return-tokens: true` → `user.accessToken` (default 1h) + `user.refreshToken` (default 30d, **rotated on every refresh**). `POST /auth/refresh` with `x-refresh-token` header; always overwrite the stored refresh token with the returned one. Refresh must be **serialized** (single-flight) and crash-safe: on servers 2.26–2.34 a lost refresh response invalidates the session (no grace window; v2.35+ has a 60s grace). Any 401 → refresh once → retry → else surface re-login.
- **OIDC SSO:** server-proxied PKCE flow via `ASWebAuthenticationSession`: `GET /auth/openid?code_challenge=…&redirect_uri=<scheme>://oauth&client_id=<AppName>&response_type=code` → capture IdP URL → system browser → callback via `/auth/openid/mobile-redirect` 302 to our custom scheme → `GET /auth/openid/callback?state&code&code_verifier` (same payload as /login). The app's scheme must be added to the server's **Allowed Mobile Redirect URIs** — needs a first-run help note. Not available on tvOS/watchOS (no browser session).
- **Tokens are device-local** (Keychain, `kSecAttrAccessibleAfterFirstUnlock` for CarPlay/background). Never synced: refresh rotation means shared tokens make devices log each other out. Only connection *metadata* syncs (see CloudSync).
- **Probing:** unauthenticated `GET /status` → `serverVersion`, `authMethods`, `authFormData` (drives login form: password vs OIDC button, custom message). Gate on ≥ 2.26.0. `POST /api/authorize` re-validates a session (returns no tokens).
- **Socket.IO v4** (server 4.5.x, EIO4; websocket transport): connect, then emit `auth` with access token; handle `init`/`auth_failed`; re-emit after every reconnect/refresh. Events consumed: `user_updated` (progress + bookmarks snapshot), `user_item_progress_updated`, `user_session_closed`, `item_added/updated/removed`, `items_added/updated`, `library_*`, `episode_added`, `episode_download_*`, `stream_reset`. Note: batch progress updates and deletions arrive only via `user_updated`. Library: socket.io-client-swift v16 — compatibility spike in M0; fallback is a 30s poll of `/api/me` + shelf refresh.
- **Data:** paginated minified item listings (`GET /api/libraries/:id/items?limit&page&sort&filter&minified=1` — always pass `limit`; omitting it dumps the whole library), `filter=<group>.<base64url(value)>`; item detail `GET /api/items/:id?expanded=1&include=progress[,downloads]`; personalized shelves `GET /api/libraries/:id/personalized`; per-library search; authors/series/collections/playlists; `filterdata` for browse UI. Covers are **unauthenticated** `GET /api/items/:id/cover?width=&ts=<updatedAt>` — no ETags anywhere, so all client caching is timestamp-keyed. Server returns no conditional-GET support; rely on the server's own response cache being cheap.
- DTOs decode the server's "old JSON" shapes tolerantly (unknown fields ignored; absent fields optional) — the API is pre-OpenAPI and drifts.

### PlayerEngine

- `AVQueuePlayer` over the session's `audioTracks`. Books are **one logical timeline**: multi-file books map global position ↔ (track index, track offset) via per-track `startOffset`/`duration`; chapters live at book level and are resolved against the global timeline. Podcasts: episode-scoped, per-episode progress.
- **Playback start:** `POST /api/items/:itemId/play[/:episodeId]` with `deviceInfo`, `mediaPlayer: "AVPlayer"`, `supportedMimeTypes` (AVPlayer-playable set). Stream URLs: prefer **`GET /public/session/:id/track/:index`** — unauthenticated, session-UUID-scoped, uniform for direct play (redirects HLS for transcode sessions), immune to 1h token expiry mid-book. Fallback for older paths: `?token=` query with regeneration after refresh. HLS transcode: handle `stream_reset` socket event / persistent segment 404 by re-seeking or re-opening the session (AVPlayer won't self-recover).
- **Progress:** `POST /api/session/:id/sync` every 15s while playing (`currentTime`, `timeListened` **delta** since last successful sync, `duration`); `POST /api/session/:id/close` on stop. Sync/close 404 (server restarted; sessions are in-memory) → recover by `POST /api/session/local` upsert of the full session JSON, then start a fresh session on next play. Manual actions (mark finished, reset progress) via `PATCH /api/me/progress/:libraryItemId[/:episodeId]`. Respect library `markAsFinishedTimeRemaining` / `markAsFinishedPercentComplete` settings.
- **Rate & pitch:** `AVPlayerItem.audioTimePitchAlgorithm = .spectral` (fallback `.timeDomain` per-setting), `AVPlayer.defaultRate` so play() resumes at chosen speed; per-book speed override (synced via CloudSync), global default speed.
- **Session config (`#if !os(macOS)`):** `.playback` / `.spokenAudio` / `.longFormAudio` (AirPlay 2 long-form path); handle interruptions (resume on `.shouldResume`) and route changes (pause on `.oldDeviceUnavailable`). Background mode `audio` on iOS/tvOS/visionOS/watchOS.
- **Now Playing:** `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` everywhere; **on macOS also set `playbackState` explicitly** (media keys depend on it). Skip-interval (15s/30s configurable) vs chapter-track commands: user preference, since lock screen/CarPlay show one pair. The WWDC26 NowPlaying framework is 27-only — revisit post-v1.
- **Sleep timer:** client-side — duration presets, end-of-chapter, fade-out ramp; shake-to-extend on iPhone (stretch).
- **Bookmarks:** server API (`POST/PATCH/DELETE /api/me/item/:id/bookmark`); list arrives in user JSON.

### LibraryCache (GRDB 7, MIT)

- `DatabasePool` (WAL) — concurrent reads during background-download writes; `ValueObservation` drives SwiftUI; FTS5 index over title/author/narrator/series for instant local search (server search supplements online).
- Cached: libraries, minified items (paged-in, keyed by `updatedAt`), item detail snapshots for downloaded/recent items, progress, filterdata, personalized shelves (short TTL), covers (disk cache keyed `itemId + updatedAt`).
- Chosen over SwiftData deliberately: background-thread write paths from URLSession delegates, identical behavior on all platforms, FTS5, and SwiftData's still-open `ModelActor` main-thread scheduling issues (per WWDC26-era reports). Revisit at OS 27.
- tvOS: same schema but treated as **purgeable cache** (Caches directory; tvOS grants no persistent local storage).

### DownloadManager

- Per-file downloads (`GET /api/items/:id/file/:ino/download?token=…`) — never the zip endpoint. Range/resume supported server-side (Express `sendFile`).
- One background `URLSessionConfiguration.background` session; ~3 concurrent; `taskDescription` = part id; `handleEventsForBackgroundURLSession` via `UIApplicationDelegateAdaptor`. On 401 mid-queue (1h token expiry): refresh, regenerate URL, retry task.
- Layout: `Documents/{libraryItemId}/…`, `isExcludedFromBackup = true`. Persisted per item: ordered tracks (ino, startOffset, duration, filename), book-level chapters, cover, metadata snapshot, server ids (connection, libraryItemId, episodeId), progress snapshot.
- **Offline progress:** local `PlaybackSession` rows (client-generated UUID, `playMethod: local`). While online playing downloaded audio: `POST /api/session/local` each sync tick. On reconnect: pull `GET /api/me` and reconcile by `lastUpdate` (newer server progress wins locally), then `POST /api/session/local-all {sessions, deviceInfo}` (server applies last-write-wins on `updatedAt`), then prune synced sessions. Matches official-app semantics.
- Podcasts: episode download + auto-delete-after-finish option; note server-side episode *fetch* queue is admin-only — v1 downloads existing episodes only.

### CloudSync

- **CKSyncEngine, private DB** — record types: `ServerConnection` (address, display name, username, authMethod, sort index; **no tokens**) and `BookPrefs` (per-item speed override, skip-interval prefs keyed by connection+item). Conflict policy: `serverRecordChanged` merge by field timestamp.
- **`NSUbiquitousKeyValueStore`** for simple prefs (default speed, sleep-timer defaults, serif/SF typeface choice, skip intervals, home-shelf order) — works on tvOS.
- Sign-in state is per-device by design (see ABSKit); a new device shows synced connections with a one-tap "sign in" prompt. tvOS: password sign-in via iPhone keyboard mirroring; **phone-assisted sign-in** (iPhone mints a session server-side and hands tokens to the TV via a short-lived CloudKit record) is a stretch goal.

### AppUI & typography

- Serif-first identity: root-level `.fontDesign(.serif)` (New York) for content typography; Settings toggle to San Francisco (`.default`). Dynamic Type throughout; monospaced digits for time/scrubber. tvOS/watchOS follow the same toggle where legible.
- Liquid Glass per HIG: glass on the floating navigation layer only, never content; `backgroundExtensionEffect` behind cover-art headers; one tinted primary action; content always scrolls under bars (esp. macOS); Icon Composer layered app icon (else Tahoe gray-boxes it).
- Shared components: cover grid/shelf row (lazy, prefetching), now-playing bar, chapter list, progress ring, download state badge.

## 4. Platform shells

- **iPhone/iPad:** Tabs — Home (personalized shelves) / Library / Search / Downloads. Full-screen player with artwork, chapter scrubber, speed, sleep timer, bookmarks, queue. iPad: `NavigationSplitView` + floating player bar. CarPlay scene: `CPTabBarTemplate` (read `maximumTabCount` at runtime) — Continue / Library / Downloads + `CPNowPlayingTemplate.shared`; works with phone locked. Widgets (continue-listening), Live Activity now-playing, Control Center `ControlWidget` play/pause via `AudioPlaybackIntent`, App Intents ("Resume my audiobook", open/search), Spotlight `IndexedEntity` for library items.
- **macOS (flagship):** `NavigationSplitView` sidebar — Home / each Library / Series / Authors / Collections / Playlists / Downloads. **Bottom-docked transport bar** (Doppler pattern; explicitly not Tahoe Music's floating player). `Table` with sortable columns for dense views; `.inspector()` for item info; right-click context menus everywhere (Play, Play Next, Mark Finished, Download, Reveal Series…); drag-and-drop out (covers/links). Full `.commands` menus — every UI action has a menu item + shortcut (playback: space, ⌘→/⌘← skip, ⌘⇧→/← chapter; ⌘F search; ⌘, Settings). `Settings` scene. Single-instance floating **mini-player** `Window` (`.windowLevel(.floating)`, `.windowResizability(.contentSize)`, restoration-aware). `MenuBarExtra` (.window style) now-playing controls. Media keys via NowPlaying/RemoteCommand (+ explicit `playbackState`). Dock menu (play/pause, recent books). Window restoration on. AppKit escape hatches accepted where SwiftUI falls short (type-to-filter key handling, precise toolbar layout, drag-session visuals). AppleScript dictionary + local MCP server: v2 differentiators, noted not designed.
- **tvOS:** streaming-only. Focus-driven shelves (Home/Libraries/Search), big-art player with chapter skimming, ambient artwork. Password sign-in (iPhone keyboard mirroring). No downloads UI; cache treated as purgeable. Background-audio behavior must be validated on hardware (M0 spike).
- **visionOS:** windowed iPad-class shell with ornament transport controls; native window resize; no immersive space in v1 (evaluate ambient "listening room" later).
- **watchOS (final milestone):** own target reusing ABSKit/PlayerEngine(+watch profile)/CloudSync. Standalone streaming over Wi-Fi/LTE; explicit "transfer to watch" offline downloads for books/episodes; local sessions sync through the same `/api/session/local-all` path; complications + Smart Stack.

## 5. Cross-cutting behavior

- **Offline-first reads:** UI renders from LibraryCache immediately with staleness indicators; network refreshes reconcile in the background. Every server mutation (progress patch, bookmark, mark-finished) goes through a persisted outbox replayed on reconnect.
- **Auth failures:** expired access → silent single-flight refresh; revoked/expired refresh → per-connection re-login prompt (other connections unaffected).
- **Transport security:** `NSAllowsArbitraryLoads = true` + usage description (user-configured self-hosted servers; App Store-accepted precedent in official app and ShelfPlayer). `NSLocalNetworkUsageDescription` (+ `NSBonjourServices` if we add Bonjour discovery later). Self-signed HTTPS: not bypassable for AVPlayer — document "install the CA profile or use HTTP/reverse proxy". macOS sandbox: `com.apple.security.network.client`.
- **Multi-server/multi-user:** connection list in CloudSync; one active connection per window context; per-connection caches namespaced in GRDB; simultaneous multi-server browsing is v2.
- **Errors:** typed `ABSError` (network / auth / server-version / not-found / permission) with user-facing recovery actions; sync loop tolerates transient failures without losing `timeListened` deltas (accumulate until a sync succeeds).

## 6. Monetization

Free app, all features free. **Tip jar**: StoreKit 2 consumable IAPs (e.g., $1.99 / $4.99 / $9.99) in Settings → "Support the app", with a thank-you state (no feature gates, no subscriptions, no badge requirements from review perspective). No ads, no tracking, no analytics beyond StoreKit's own.

## 7. App Store & legal

- Name: "Colophon — for Audiobookshelf" (nominative use; matches Still/Absorb precedent).
- Review prep: hosted demo ABS server + demo credentials in review notes (reviewers must exercise login/playback); note explaining self-hosted-server requirement (Plex/Jellyfin precedent).
- **CarPlay audio entitlement (`com.apple.developer.carplay-audio`): apply at project start** — case-by-case approval, days-to-weeks, blocks even building the CarPlay scene with a real profile.
- Licenses: GRDB (MIT), socket.io-client-swift (MIT), AudiobookshelfKit (MIT, reference only). Never copy from ShelfPlayer (MPL + Commons Clause) or GPL projects (official app, absorb, swiftshelf). AudioBooth (plain MPL-2.0): study freely; any copied file keeps MPL notice — prefer clean-room.
- Our license: TBD with user (open-sourcing was not selected; default private).

## 8. Testing strategy

- **ABSKit:** unit tests against captured fixture JSON per endpoint + auth state-machine tests (refresh rotation, single-flight, 401 replay). Contract tests runnable against a local ABS server in Docker (`advplyr/audiobookshelf` image) for CI-optional integration.
- **PlayerEngine:** deterministic tests with a fake clock/player protocol — timeline math (multi-file offset ↔ global position, chapter resolution), sync-delta accounting, sleep-timer edges.
- **DownloadManager:** simulated background-session callbacks; 401-mid-queue refresh/retry; resume-data paths.
- **CloudSync:** conflict-merge unit tests; manual multi-device checklist.
- **UI:** snapshot tests for AppUI components in both typefaces/appearances; XCUITest smoke per platform (launch → browse → play).
- **M0 spikes (research-flagged unknowns):** socket.io-client-swift v16 handshake against server 4.5.x; LazyVGrid/Table perf with 5–10k items on macOS; tvOS background-audio on hardware; OIDC callback cookie behavior with a cookie-less URLSession.

## 9. Milestones

- **M0 — Walking skeleton + spikes.** Repo/workspace/package scaffold; CarPlay entitlement application filed; ABSKit auth (password) + library list; play one book end-to-end (streaming) on iPhone **and** Mac; the four spikes above.
- **M1 — Streaming core (iPhone/iPad/Mac).** Home shelves, library browse/sort/filter, search, item detail, full player (chapters/speed/sleep/bookmarks), session sync + socket live updates, covers cache, OIDC login, multi-connection management, serif/SF setting.
- **M2 — Offline + companions.** Downloads with background sessions, offline playback + local-session sync-back, CarPlay UI, widgets, Live Activity, Control widgets, App Intents/Siri/Spotlight, tip jar.
- **M3 — Mac flagship polish.** Menu bar extra, mini-player window, full command set, Table/inspector views, dock menu, drag-and-drop, window restoration audit, keyboard-navigation audit, Control Center widget.
- **M4 — tvOS + visionOS.** Streaming-only TV shell + sign-in flow; visionOS ornament player + window polish.
- **M5 — watchOS.** Standalone watch app, transfer-to-watch downloads, complications.
- **Ship:** App Store assets, demo server for review, privacy labels (none collected), phased release.

Each milestone ends with the superpowers verification/review flow before moving on.

## 10. Risks

| Risk | Mitigation |
|---|---|
| socket.io-client-swift incompatibility | M0 spike; poll fallback keeps v1 shippable |
| SwiftUI Mac rough edges (drag, toolbars, key handling) | Planned AppKit escape hatches; budget in M3 |
| tvOS background audio unreliable | M0 hardware spike; worst case: audio stops on backgrounding (acceptable for TV) |
| CarPlay entitlement delay/denial | Applied at M0; CarPlay UI is M2 — weeks of slack |
| ABS API drift (pre-OpenAPI server) | Tolerant DTO decoding; contract tests against pinned + latest server images |
| Large-library performance | Paged minified fetches; FTS5 local search; macOS grid perf spike; NSCollectionView fallback |
| App Review friction (self-hosted server) | Demo server + credentials in notes; precedent apps documented |

## 11. Open decisions

1. **Source license / repo visibility** — user preference; nothing blocks on it.
2. Post-v1 candidates (explicitly deferred): simultaneous multi-server browsing, AppleScript + MCP server on Mac, ambient visionOS space, stats/year-in-review views, ebook support.

*(Resolved 2026-07-06: app name = Colophon.)*
