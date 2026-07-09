# Colophon M2a — Offline downloads + offline playback + sync-back

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A book or podcast episode can be downloaded via a background `URLSession`, played with **no network** from local files, and its offline progress reconciles cleanly with the server on reconnect (last-write-wins, no double-counted listen time).

**Architecture:** A new `DownloadManager` package owns background `URLSession` transfers behind a testable seam (Fake session for unit tests). LibraryCache gains a v4 (additive) download-records table + pinned detail so downloaded items are fully browsable offline. `PlayerEngine.load(trackURLs:)` already accepts arbitrary URLs, so offline playback feeds `file://` URLs (`playMethod: local`) with chapters/timeline from cached detail. Offline progress is written as local `PlaybackSession` rows and reconciled via the existing `/api/session/local` plumbing (M1a) plus `POST /api/session/local-all`. An `NWPathMonitor` reachability signal makes browse fall back to cache/downloads offline.

**Tech Stack:** Swift 6.2 strict concurrency (complete), default-MainActor, `@Observable`; a new `DownloadManager` SwiftPM package (background `URLSession`); GRDB v4 additive migration; AVFoundation local-file playback; existing ABSKit/PlayerEngine/LibraryCache.

## Global Constraints

- All prior constraints bind: Swift 6.2 strict concurrency (complete), default-MainActor; targets iOS/iPadOS/macOS/tvOS/visionOS/watchOS **26+**; bundle `com.andrewthom.colophon` (team LL334G7KP2); server ≥ 2.26.0; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **UI MANDATE (review criterion):** native-first Liquid Glass, HIG-idiomatic per platform. Glass ONLY on transport/nav chrome; content/rows/badges opaque; one `.glassProminent` primary per surface.
- **macOS gotchas (both real-Mac-only, build-invisible — from M1c):** (1) SplitShell/split-view column `navigationDestination` MUST be registered INSIDE the column `NavigationStack` on root content; (2) every `.sheet` needs `#if os(macOS) .frame(minWidth:minHeight:) #endif` (`.presentationDetents` is iOS-only). Any new Downloads surface/sheet MUST follow both.
- **AUDIO SAFETY:** `COLOPHON_AUTO_MUTE=1` on every E2E; ALWAYS terminate the app after; cap idb screenshots at ≤3, stop after 2 idb failures.
- **Schema:** v1/v2/v3 FROZEN. M2a adds `registerMigration("v4")` — ALTER-only + CREATE, never editing prior migrations. `#if DEBUG eraseDatabaseOnSchemaChange` stays; add real-old-DB migration tests (seed a v3 DB → migrate → v4 rows coexist).
- **Downloads endpoint:** per-file ONLY — `GET /api/items/:id/file/:ino/download?token=<accessToken>` — NEVER the zip endpoint. Range/resume is server-supported (Express `sendFile`).
- **Offline progress semantics (spec §3, match the official app EXACTLY):** local `PlaybackSession` rows carry a client-generated UUID + `playMethod: local`; while ONLINE playing downloaded audio, `POST /api/session/local` each sync tick; on reconnect: `GET /api/me` and reconcile by `lastUpdate` (newer **server** progress wins locally), THEN `POST /api/session/local-all {sessions, deviceInfo}` (server applies last-write-wins on `updatedAt`), THEN prune synced sessions. Never double-count `timeListened`.
- **No silent data loss:** never drop a queued download or a local session without surfacing it; storage use is always visible.
- **Reuse, not fork:** offline playback goes through the SAME `PlayerEngine`/`AppState.startPlayback` path (a local-source variant), NOT a parallel player. Downloaded podcast episodes reuse the episode playback path (M1c-c).

## Verified reference (M2a confirms live where it can; the dev server is UP at localhost:13378)

```
Per-file download: GET /api/items/:id/file/:ino/download?token=<accessToken>   (auth via query token; range/resume OK)
Item detail (for the file/ino list + audioTracks): GET /api/items/:id?expanded=1  (media.audioFiles[].ino, .metadata; audioTracks contentUrl)
Local session sync (exists, M1a): POST /api/session/local  {id, currentTime, timeListened, duration, ...}
Local session batch reconcile: POST /api/session/local-all  {sessions:[…], deviceInfo}
Reconcile source: GET /api/me  (mediaProgress[] with lastUpdate; newer server wins locally)
Podcast episode file: the episode's audioFile.ino via the same /file/:ino/download route on the podcast item id.
```

## File Structure (M2a new/changed)

```
Packages/DownloadManager/…                         NEW  background URLSession behind a DownloadSession seam + FakeDownloadSession; per-file transfer, progress, cancel, resume
Packages/LibraryCache/.../Schema.swift             MOD  v4 migration: cachedDownload table (+ pinned detail already via cachedItemDetail)
Packages/LibraryCache/.../Records.swift            MOD  CachedDownload record
Packages/LibraryCache/.../LibraryCacheStore.swift  MOD  upsert/observe/delete downloads; downloads() query; storage totals
Packages/ABSKit/.../ABSClient.swift                MOD  fileDownloadURL(itemID:ino:token:); syncLocalSessions([…]) → POST /api/session/local-all; me() reconcile helper
Packages/PlayerEngine/.../SessionSyncController.swift  MOD  local-session accrual (offline queueing of ticks)
App/Downloads/DownloadCoordinator.swift            NEW  AppState-owned: download item/episode (detail→enumerate files→enqueue→track→pin), delete, storage; observes DownloadManager
App/AppState.swift                                 MOD  reachability (NWPathMonitor), offline-aware startPlayback (local file URLs), local-session reconcile on reconnect
App/Views/DownloadsView.swift                      NEW  Downloads tab (downloaded items/episodes, state, storage, delete/manage)
App/Views/DownloadButton.swift + badges           NEW  download/delete affordance + state badge on ItemDetail/EpisodeDetail/PodcastDetail/CoverCard/EpisodeRow
App/Shell/{PhoneShell,SplitShell}.swift            MOD  Downloads tab / sidebar entry; offline banner
project.yml                                        MOD  DownloadManager package dep; background modes already set (audio) — add fetch/processing if needed
```

---

### Task 1: DownloadManager package — background transfer behind a testable seam

**Files:** Create `Packages/DownloadManager/…` (Package.swift, sources, tests); `project.yml` (add the package dep to the app).

Create the 4th local package. Define a `DownloadSession` protocol seam (the subset of `URLSession` download behavior the manager needs: start a download task for a `URLRequest` → progress callbacks (bytesWritten/total) + completion with the temp file URL or error; cancel; resume-data support) so the manager is unit-testable with a `FakeDownloadSession` (no network). Provide a real `URLSessionDownloadSession` backed by `URLSession(configuration: .background(withIdentifier:))` with a delegate bridging `urlSession(_:downloadTask:didWriteData:…)` / `didFinishDownloadingTo` / `didCompleteWithError` to async streams. The manager: `enqueue(fileID:request:destination:)`, per-file progress + terminal state, `cancel(fileID:)`, and (background) app-relaunch completion-handler storage (`handleEventsForBackgroundURLSession` hook — expose a `func setBackgroundCompletionHandler(_:)`). No cache/UI knowledge — pure transfer.

- [ ] TDD with `FakeDownloadSession`: enqueue → progress ticks → moves the temp file to destination → terminal `.downloaded`; cancel mid-flight → `.cancelled`, no file; failure → `.failed(error)`, no partial left at destination; concurrent enqueues are independent. `cd Packages/DownloadManager && swift test`. Commit `feat(DownloadManager): background per-file transfer behind a testable seam`.

---

### Task 2: LibraryCache v4 — download records

**Files:** `Schema.swift` (v4), `Records.swift` (`CachedDownload`), `LibraryCacheStore.swift`; tests.

`registerMigration("v4")` (ALTER/CREATE only): a `cachedDownload` table keyed `(connectionID, itemID, episodeID)` (episodeID `""` for books, matching the 3-part progress PK convention) with: `state` (queued/downloading/downloaded/failed), `receivedBytes`, `totalBytes`, a per-file breakdown (the audioTrack index → ino → local relative path → state; store as a child table `cachedDownloadFile` or a JSON column — pick the cleaner given GRDB usage), `pinnedDetail` reuse of the existing `cachedItemDetail` (downloaded items MUST have their detail pinned so they're browsable offline), `updatedAt`. Store local paths RELATIVE to a known downloads root (absolute paths break across app-container moves). Add: `upsertDownload`, `download(connectionID:itemID:episodeID:)`, `downloads(connectionID:)`, `observeDownloads(connectionID:)`, `deleteDownload(…)`, `totalDownloadedBytes(connectionID:)`. Real-old-DB test: seed a v3 DB, migrate, assert v1/v2/v3 rows survive + v4 table usable.

- [ ] TDD: `cd Packages/LibraryCache && swift test` (download round-trip, observe emits, per-file breakdown, relative-path storage, v3→v4 migration preserves rows). Commit `feat(LibraryCache): v4 download records (additive migration)`.

---

### Task 3: ABSKit download URL + local-session batch reconcile

**Files:** `ABSClient.swift`, `Models.swift`; fixtures + tests.

Add: `func fileDownloadURL(itemID:ino:) -> URL` (builds `GET /api/items/:id/file/:ino/download?token=<accessToken>` with the current access token — the download runs in a background session, so it takes a plain authed URL, not the shared client session); `func syncLocalSessions(_ sessions: [LocalSessionPayload]) async throws` → `POST /api/session/local-all {sessions, deviceInfo}`; and a `me()`-based reconcile helper returning server `mediaProgress` for last-write-wins comparison (me() already exists — add a typed reconcile view if useful). Ground the local-session payload shape against the existing `/api/session/local` code (M1a) + the spec. Opt-in ContractTests: POST a local-all batch live, then verify /api/me reflects it, then reset.

- [ ] Decode/URL tests + opt-in live ContractTests. `cd Packages/ABSKit && swift test`. Commit `feat(ABSKit): file-download URL + local-session batch reconcile`.

---

### Task 4: DownloadCoordinator — orchestrate download/delete/storage

**Files:** Create `App/Downloads/DownloadCoordinator.swift` (AppState-owned `@Observable`); wire into `AppState`.

Orchestrates: `download(itemID:episodeID:)` → ensure detail is fetched + PINNED (cachedItemDetail) → enumerate the item's audio files (audioFiles[].ino for a book; the episode's audioFile.ino for an episode) → enqueue each via DownloadManager to a downloads-root destination → track aggregate `CachedDownload.state`/bytes as per-file progress streams in → on all-files-complete write local relative paths + `.downloaded`; `delete(itemID:episodeID:)` → cancel any in-flight + remove files + delete records; storage totals; resume in-flight downloads on launch (reconcile DownloadManager's background-session state with cache records — a download that finished while the app was dead must be reconciled). Subscribes to DownloadManager progress; writes LibraryCache. NO parallel player/network — reuses ABSKit + LibraryCache.

- [ ] Tests (Fake DownloadManager + in-memory store): download book (multi-file) → per-file progress aggregates → `.downloaded` with pinned detail + relative paths; delete removes files+records; a failed file → `.failed` (no partial); relaunch reconcile marks a background-finished download `.downloaded`. `make test-app`. Commit `feat(app): download coordinator (orchestrate download/delete/storage)`.

---

### Task 5: Offline playback (local file URLs through the shared player)

**Files:** `App/AppState.swift` (startPlayback offline-source variant), PlayerEngine as needed.

When the item/episode is `.downloaded`, `startPlayback` uses the LOCAL file URLs (resolve the cached relative paths → `file://` URLs) + the cached detail's chapters/timeline, calling `PlayerEngine.load(session:trackURLs:)` with `playMethod: local` and NO `/play` HLS session for the stream. A partially-downloaded or not-downloaded item still streams (existing path). Selection rule: prefer local when fully downloaded, else stream (document the rule; a settings "prefer downloads" is post-v1). The now-playing/progress/queue/sleep/bookmarks all work identically (they key off the player, not the source). Guard: same reentrancy/epoch/retire guards as the streaming path — NO forked guard logic.

- [ ] Tests (MockTransport + a fake local file): startPlayback for a downloaded item loads file:// URLs (no /play call) + sets playMethod local; a non-downloaded item still streams; guards reused. CAPPED MUTED E2E: download a book (or use a seeded pre-download) → airplane/stop network → play it → audio plays from local. Commit `feat(app): offline playback from downloaded files`.

---

### Task 6: Local-session sync-back + reachability

**Files:** `App/AppState.swift` (NWPathMonitor + reconcile-on-reconnect), `SessionSyncController.swift` (local accrual), `ABSClient` (from Task 3).

Reachability: an `NWPathMonitor`-backed `isOffline` signal on AppState. Offline playback of downloaded audio writes local `PlaybackSession` rows (client UUID, `playMethod: local`) accruing `timeListened`; while ONLINE, `POST /api/session/local` per tick (existing path). On reconnect (isOffline→online): `GET /api/me` → reconcile each item's progress by `lastUpdate` (newer SERVER wins locally, else keep local), then `POST /api/session/local-all` the pending local sessions, then prune synced rows. NEVER double-count `timeListened` across the offline→online seam. This is the highest-risk correctness surface — adversarial concurrency tests (a tick landing mid-reconnect; a reconcile racing a new local tick).

- [ ] Tests: offline ticks accrue local sessions; reconnect reconcile is last-write-wins (server-newer wins; local-newer pushed); no double-count; a tick during reconcile is not lost/duplicated (RED-verify the guard by dropping it). `make test`. Commit `feat(app): offline local-session sync-back + reachability`.

---

### Task 7: Downloads tab + offline-aware browse

**Files:** Create `App/Views/DownloadsView.swift`; `App/Shell/{PhoneShell,SplitShell}.swift` (Downloads tab/sidebar + offline banner).

A Downloads tab (iPhone/iPad: a 4th tab per spec §7; Mac: a sidebar entry — respect the macOS nav gotcha) listing downloaded books + episodes with state (downloading progress / downloaded / failed-retry), total storage used, and delete/manage (swipe + context). When `isOffline`, Home/Library/Search gracefully fall back to cache+downloads (no spinners-forever; a subtle offline banner; network-only actions disabled with feedback). Native loading/empty/error (`ContentUnavailableView`).

- [ ] Build both; native-UI review; CAPPED MUTED E2E: Downloads tab lists a downloaded item with storage; toggle offline → Home/Library still render from cache. Commit `feat(app): downloads tab + offline-aware browse`.

---

### Task 8: Download affordances + state badges (+ podcast auto-delete)

**Files:** Create `App/Views/DownloadButton.swift`; wire into `ItemDetailView`, `EpisodeDetailView`, `PodcastDetailView`/`EpisodeRow`, `CoverCard`.

A reusable download/delete control (download → progress → downloaded → delete) on item detail, episode detail, and per-episode rows; a compact download-state badge on `CoverCard`/`EpisodeRow`. Podcast episodes: a "delete after finished" option (per spec) — auto-remove a downloaded episode's files once its progress marks finished (a settings toggle; default off). Glass discipline: the button is a plain/bordered control, not glass (glass stays on transport chrome).

- [ ] Build both; native-UI review; CAPPED MUTED E2E: item detail download button drives progress→downloaded→delete; badge shows on the cover; episode download works. Commit `feat(app): download affordances + state badges`.

---

### Task 9: Wrap-up + human-verification + final review

**Files:** `README.md`; `docs/superpowers/m2a-human-verification.md`; contract-block refresh.

- [ ] README → M2a reality (offline downloads, offline playback, sync-back, Downloads tab, badges). Human-verification checklist (device-only: background download continues when app backgrounded/killed→relaunched; offline playback across an app relaunch; offline→online progress reconcile with no double-count; storage accounting; podcast auto-delete). Full cold-start sweep `make test && make test-app && make build-ios && make build-mac` green, zero warnings. Commit `docs: M2a status`. Then the whole-branch adversarial review before merge.

---

## Self-review notes (plan-writing time)

- **Coverage vs M2 overview §M2a:** DownloadManager package (T1), v4 download records (T2), file-download URL + local-all reconcile (T3), download orchestration/delete/storage (T4), offline playback via shared player (T5), local-session sync-back + reachability (T6), Downloads tab + offline-aware browse (T7), affordances/badges + podcast auto-delete (T8), wrap-up+review (T9).
- **Grounding-first:** the dev server is UP — T3 confirms the download URL + local-all shapes live; T1/T2 are pure-unit (Fake session / in-memory store) so they need no live server. Highest-risk surface (T6 offline↔online reconcile) gets adversarial concurrency tests like M1c-b's queue race.
- **Reuse, not rebuild:** offline playback reuses `PlayerEngine.load(trackURLs:)` (already URL-agnostic) + the same startPlayback guards; local-session sync extends the M1a `/api/session/local` plumbing; downloaded podcast episodes reuse the M1c-c episode path. No new migration beyond the additive v4.
- **macOS gotchas** baked into Global Constraints so the Downloads tab/sheets don't repeat the real-Mac bugs.
- **Deferred beyond M2a:** widgets/Live Activity/Siri/Spotlight (M2b), tip jar + CarPlay (M2c), "prefer downloads" playback setting + download quality/eviction policies (post-v1), watch transfer-to-watch downloads (M5).
